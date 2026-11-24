# frozen_string_literal: true

require 'rails_helper'

# Phase 15: the Sources manifest queue never queues a second extraction of a PDF already queued or running, whether
# the first one came from the board / the planner (logged under the FIN event id) or from the Sources page (logged
# under the PDF source key, or under the FIN event id for a FIN row's PDF), in either order.
RSpec.describe Sources::ManifestQueue do
  include ActiveJob::TestHelper

  subject(:queue) { described_class.new(season_id: 242, data_root:) }

  let(:data_root) { Pathname.new(Dir.mktmpdir('manifest-queue-')).realpath }
  let(:manifests_dir) { data_root.join('manifests', '242') }
  let(:fin_url) { 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/150091:x.html' }
  let(:fin_pdf) { manifests_dir.join('manifest-2026-11-08-Fin.pdf') }
  let(:other_pdf) { manifests_dir.join('manifest-2026-11-09-Other.pdf') }

  def extract_jobs = enqueued_jobs.select { |job| job['job_class'] == 'ManifestExtractJob' }

  def job_args = extract_jobs.map { |job| ActiveJob::Arguments.deserialize(job['arguments']).first.symbolize_keys }

  before(:each) do
    FileUtils.mkdir_p(manifests_dir)
    [fin_pdf, other_pdf].each { |path| File.write(path, '%PDF') }
    results_dir = data_root.join('results.new', '242')
    FileUtils.mkdir_p(results_dir)
    File.write(results_dir.join('2026-11-08-Fin.json'), { 'layoutType' => 2, 'meetingURL' => fin_url, 'sections' => [] }.to_json)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    allow(SeasonBoard::Notifier).to receive(:ping)
    allow(SeasonBoard::Snapshot).to receive(:invalidate!)
  end

  after(:each) do
    FileUtils.rm_rf(data_root)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  it 'queues a FIN row PDF through the board scheduler (FIN key, batch priority) and the others under their source key' do
    expect(queue.enqueue_next(20)).to eq(2)
    expect(job_args).to contain_exactly({ season_id: 242, fin_event_id: '150091', engine: nil },
                                        { season_id: 242, pdf_path: other_pdf.to_s, engine: nil })
    expect(extract_jobs.pluck('priority')).to eq([10, 10])
    log = SeasonBoard::ActivityLog.new
    expect(log.entry('150091', :extract)).to have_attributes(status: :queued)
    expect(log.entry(SeasonBoard::ActivityLog.source_key('extract', other_pdf.to_s), :extract)).to have_attributes(status: :queued, label: other_pdf.basename.to_s)
  end

  it 'skips a PDF the board (or the planner) already queued, and the board refuses one the Sources batch queued' do
    expect(SeasonBoard::Scheduler.extract!(season_id: 242, fin_event_id: '150091', pdf_path: fin_pdf.to_s)).to be true
    expect(queue.enqueue_next(20)).to eq(1)
    expect(job_args.pluck(:fin_event_id).compact).to eq(['150091'])

    clear_enqueued_jobs
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    expect(queue.enqueue_next(20)).to eq(2)
    expect(SeasonBoard::Scheduler.extract!(season_id: 242, fin_event_id: '150091', pdf_path: fin_pdf.to_s)).to be false
    expect(described_class.new(season_id: 242, data_root:).enqueue(fin_pdf.to_s)).to be false
    expect(described_class.new(season_id: 242, data_root:).enqueue(other_pdf.to_s)).to be false
    expect(extract_jobs.size).to eq(2)
  end

  it 'lets the board refuse a PDF busy under its Sources key (queued before its FIN id was known)' do
    key = SeasonBoard::ActivityLog.source_key('extract', fin_pdf.to_s)
    SeasonBoard::ActivityLog.new.queue!(key, kind: :extract, origin: :manual)
    expect(SeasonBoard::Scheduler.extract!(season_id: 242, fin_event_id: '150091', pdf_path: fin_pdf.to_s)).to be false
    expect(queue.enqueue(fin_pdf.to_s)).to be false
    expect(extract_jobs).to be_empty
  end

  it 'never queues a PDF of the batch that resolves outside manifests/<season> (a symlink pointing out)' do
    outside = Pathname.new(Dir.mktmpdir('manifest-outside-')).join('evil.pdf')
    File.write(outside, '%PDF')
    File.symlink(outside, manifests_dir.join('manifest-zz-link.pdf'))
    expect(queue.enqueue_next(20)).to eq(2)
    expect(job_args.filter_map { |args| args[:pdf_path] }).to eq([other_pdf.to_s])
  ensure
    FileUtils.rm_rf(outside.dirname) if outside
  end
end
