# frozen_string_literal: true

require 'rails_helper'
require 'digest'

# (phase 09) Review GETs stop writing: once a source is settled, a review GET changes no file (mtimes and contents).
#
# The only writes a review GET still makes are idempotent and happen once per phase file (pinned by the unchanged
# 01 characterization spec): the '_meta' of the step's own phase file gets the retry flag and, for a pre-existing
# file, the 'adopted' build stamp; the Step 3 harmonizer writes phase 2 only when a NEW conflict hint appears
# (normally at build time). Phase data is never written by a GET.
RSpec.describe 'Data-Fix review GETs write nothing on a settled source' do
  include AdminSignInHelpers

  let(:fixtures_dir) { Rails.root.join('spec/fixtures/import') }
  let(:basename) { 'sample-200RA-l4' }
  let(:tmp_root) { Dir.mktmpdir('no-write-on-get-') }
  let(:work_dir) { File.join(tmp_root, '242') }
  let(:source_path) { File.join(work_dir, "#{basename}.json") }
  let(:steps) do
    [[:review_sessions, 'phase_v2'], [:review_teams, 'phase2_v2'], [:review_swimmers, 'phase3_v2'],
     [:review_events, 'phase4_v2'], [:review_results, 'phase5_v2']]
  end

  before(:each) do
    sign_in_admin(prepare_admin_user)
    FileUtils.mkdir_p(work_dir)
    FileUtils.cp(fixtures_dir.join("#{basename}.json"), work_dir)
    FileUtils.cp(Dir[fixtures_dir.join("#{basename}-phase*.json")], work_dir)
  end

  after(:each) { FileUtils.rm_rf(tmp_root) }

  def snapshot
    sleep(0.02) # (stay clear of the file system timestamp granularity)
    Dir.glob(File.join(work_dir, '*')).to_h { |path| [File.basename(path), [File.mtime(path), Digest::SHA256.file(path).hexdigest]] }
  end

  def visit_all
    steps.each do |action, flag|
      get(send(:"#{action}_path", file_path: source_path, flag => 1))
      expect(response).to have_http_status(:ok), "#{action}: #{response.status}"
    end
  end

  it 'settles each phase file on its first GET (metadata only), then writes nothing on any later GET' do
    visit_all # (first visit: retry flag + adopted stamp of each own phase file)
    settled = snapshot

    visit_all
    expect(snapshot).to eq(settled)
  end

  it 'never changes the phase data on a review GET, not even on the first one' do
    digests = (1..5).index_with { |phase| PhaseFileManager.new(File.join(work_dir, "#{basename}-phase#{phase}.json")).data_digest }
    visit_all
    expect((1..5).index_with { |phase| PhaseFileManager.new(File.join(work_dir, "#{basename}-phase#{phase}.json")).data_digest })
      .to eq(digests)
  end
end
