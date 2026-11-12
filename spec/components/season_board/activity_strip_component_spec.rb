# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoard::ActivityStripComponent, type: :component do
  around(:each) { |example| I18n.with_locale(:en) { example.run } }

  let(:now) { Time.zone.local(2026, 11, 12, 10, 10) }
  let(:recurring_file) { Tempfile.new(['recurring', '.yml']) }
  let(:recurring_path) { recurring_file.path }

  before(:each) do
    recurring_file.write(<<~YML)
      default: &default
        federnuoto_watch:
          class: FedernuotoWatchJob
          schedule: every hour at minute 30
        season_board_recheck:
          class: SeasonRecheckJob
          schedule: every day at 06:15
      test:
        <<: *default
    YML
    recurring_file.flush
  end

  after(:each) { recurring_file.close! }

  def entry(status:, origin: :auto, kind: :crawl, fin_id: '150091', **attrs)
    SeasonBoard::ActivityLog::Entry.new(
      fin_event_id: fin_id, kind:, origin:, status:, queued_at: Time.zone.local(2026, 11, 12, 9, 55), started_at: nil,
      finished_at: nil, url: nil, message: nil, **attrs
    )
  end

  def render_strip(activities, **options)
    render_inline(described_class.new(activities:, names: { '150091' => 'Trofeo Test' }, recurring_path:, now:, **options))
  end

  it 'shows the idle message when nothing is queued or running' do
    expect(render_strip([]).text).to include('Nothing queued or running.')
  end

  it 'shows a running activity with the meeting name, start time & origin' do
    running = entry(status: :running, started_at: Time.zone.local(2026, 11, 12, 10, 1))
    text = render_strip([running]).text
    expect(text).to include('Running now', 'Trofeo Test: crawl since 10:01 (automatic)')
  end

  it 'falls back to the FIN id when the meeting name is unknown' do
    running = entry(status: :running, fin_id: '999', started_at: Time.zone.local(2026, 11, 12, 10, 1))
    expect(render_strip([running]).text).to include('FIN #999')
  end

  it 'counts the queued activities' do
    queued = [entry(status: :queued), entry(status: :queued, fin_id: '2'), entry(status: :queued, fin_id: '3', kind: :extract)]
    expect(render_strip(queued).text).to include('Queued: 3')
  end

  it 'shows the next scheduled runs from the recurring tasks' do
    text = render_strip([]).text
    expect(text).to include('Next FIN page check:', 'Next daily re-check:')
  end

  context 'with the daily re-check key missing' do
    before(:each) do
      recurring_file.truncate(0)
      recurring_file.rewind
      recurring_file.write("test:\n  federnuoto_watch:\n    schedule: every hour at minute 30\n")
      recurring_file.flush
    end

    it 'shows only the available next run' do
      text = render_strip([]).text
      expect(text).to include('Next FIN page check:')
      expect(text).not_to include('Next daily re-check:')
    end
  end

  context 'with an unparsable schedule or a missing file' do
    it 'shows no scheduled runs for an unparsable schedule' do
      recurring_file.truncate(0)
      recurring_file.rewind
      recurring_file.write("test:\n  federnuoto_watch:\n    schedule: whenever you like\n")
      recurring_file.flush
      expect(render_strip([]).text).not_to include('Next FIN page check:')
    end

    it 'shows no scheduled runs for a missing file' do
      text = render_inline(described_class.new(activities: [], names: {}, recurring_path: '/no/such/file.yml', now:)).text
      expect(text).not_to include('Next ')
      expect(text).to include('Nothing queued or running.')
    end
  end

  describe '.crawler_confirm_text' do
    let(:log) { instance_double(SeasonBoard::ActivityLog) }

    before(:each) { allow(SeasonBoard::ActivityLog).to receive(:new).and_return(log) }

    it 'keeps the default text when nothing automatic is running or queued' do
      allow(log).to receive(:active).and_return([])
      expect(described_class.crawler_confirm_text('Run?')).to eq('Run?')
    end

    it 'mentions the running crawl' do
      allow(log).to receive(:active).and_return([entry(status: :running, started_at: now)])
      text = described_class.crawler_confirm_text('Run?')
      expect(text).to include('An automatic crawl is running', 'FIN #150091', 'Run?')
    end

    it 'mentions the queued automatic crawls' do
      allow(log).to receive(:active).and_return([entry(status: :queued), entry(status: :queued, fin_id: '2')])
      expect(described_class.crawler_confirm_text('Run?')).to include('queued (2)')
    end
  end
end
