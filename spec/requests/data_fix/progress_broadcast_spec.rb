# frozen_string_literal: true

require 'rails_helper'

# The Data-Fix requests broadcast their progress on ImportStatusChannel (the progress strip under the top bar) only
# while they build something: one operation (op) per request, with an increasing seq and the source base name as
# scope, ended by one 'done'. A plain review GET that builds nothing broadcasts nothing (no more "ready" message,
# which used to open the progress modal on every review page).
RSpec.describe 'Data-Fix progress broadcasts' do
  include AdminSignInHelpers

  let(:fixtures_dir) { Rails.root.join('spec/fixtures/import') }
  let(:basename) { 'sample-200RA-l4' }
  let(:tmp_root) { Dir.mktmpdir('progress-broadcast-') }
  let(:work_dir) { File.join(tmp_root, '242') } # (the season ID is read from the folder name)
  let(:source_path) { File.join(work_dir, "#{basename}.json") }
  let(:broadcasts) { [] }

  before(:each) do
    sign_in_admin(prepare_admin_user)
    FileUtils.mkdir_p(work_dir)
    FileUtils.cp(fixtures_dir.join("#{basename}.json"), work_dir)
    allow(ActionCable.server).to receive(:broadcast) do |channel, payload|
      broadcasts << payload if channel == Import::Progress::Cable::CHANNEL
    end
  end

  after(:each) { FileUtils.rm_rf(tmp_root) }

  context 'with every phase file in place (plain review GETs)' do
    before(:each) { FileUtils.cp(Dir[fixtures_dir.join("#{basename}-phase*.json")], work_dir) }

    [[:review_teams, 'phase2_v2'], [:review_swimmers, 'phase3_v2'], [:review_results, 'phase5_v2'],
     [:review_sessions, 'phase_v2'], [:review_events, 'phase4_v2']].each do |action, flag|
      it "broadcasts nothing on #{action}" do
        2.times do # (the first GET settles the phase file metadata, the second is a plain one)
          get(send(:"#{action}_path", file_path: source_path, flag => 1))
          expect(response).to have_http_status(:ok)
        end
        expect(broadcasts).to be_empty
      end
    end
  end

  context 'when a review GET builds its phase' do
    before(:each) { FileUtils.cp(fixtures_dir.join("#{basename}-phase1.json"), work_dir) }

    let(:review_path) { review_teams_path(file_path: source_path, phase2_v2: 1) }

    it "sends the solver ticks under one op (increasing seq, scope: the source name), then one 'done'" do
      get(review_path)
      expect(response).to redirect_to(review_path)

      ticks = broadcasts.reject { |payload| payload[:state] }
      expect(ticks.pluck(:msg)).to include('Map teams')
      op = ticks.first[:op]
      expect(broadcasts.pluck(:op)).to all(eq(op)) # (the solver uses the request's own sink)
      expect(ticks.pluck(:seq)).to eq((1..ticks.size).to_a)
      expect(ticks.pluck(:scope)).to all(eq(basename))
      expect(broadcasts.last).to eq({ op:, state: 'done' })
      expect(broadcasts.count { |payload| payload[:state] == 'done' }).to eq(1)
    end

    it 'broadcasts nothing on the GET it redirects to' do
      get(review_path)
      broadcasts.clear
      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(broadcasts).to be_empty
    end
  end

  context 'with a POST that reports its progress ("Verify all" of Step 5)' do
    let(:verifier) { instance_double(DataFix::ResultVerifier) }
    let(:message) { I18n.t('data_fix.verify_all.progress') }

    before(:each) do
      FileUtils.cp(Dir[fixtures_dir.join("#{basename}-phase*.json")], work_dir)
      allow(DataFix::ResultVerifier).to receive(:new).and_return(verifier)
    end

    it "sends its ticks (also from inside the verification) and one 'done' under a single op" do
      allow(verifier).to receive(:verify_all!) do |progress:, message:|
        progress.call(message, 1, 2)
        progress.call(message, 2, 2)
        { 'checked' => 2 }
      end
      post(data_fix_verify_all_results_path(file_path: source_path))
      expect(response).to have_http_status(:redirect)
      expect(broadcasts.pluck(:op).uniq.size).to eq(1)
      expect(broadcasts.map { |payload| payload[:seq] || payload[:state] }).to eq([1, 2, 3, 'done'])
      expect(broadcasts.filter_map { |payload| payload[:msg] }).to all(eq(message))
    end

    it "still sends the 'done' when the action raises after a tick" do
      allow(verifier).to receive(:verify_all!) do |progress:, message:|
        progress.call(message, 1, 2)
        raise ArgumentError, 'verifier exploded'
      end
      expect { post(data_fix_verify_all_results_path(file_path: source_path)) }.to raise_error(ArgumentError, 'verifier exploded')
      op = broadcasts.first[:op]
      expect(broadcasts.map { |payload| payload[:seq] || payload[:state] }).to eq([1, 2, 'done'])
      expect(broadcasts.last).to eq({ op:, state: 'done' })
    end
  end

  context 'with an action that rescues a failure and redirects (the category recompute of Step 1)' do
    before(:each) { FileUtils.cp(Dir[fixtures_dir.join("#{basename}-phase*.json")], work_dir) }

    it "sends the 'done' after the ticks sent before the failure" do
      allow(DataFix::CategoryRecomputer).to receive(:new) do |progress:, **|
        instance_double(DataFix::CategoryRecomputer).tap do |recomputer|
          allow(recomputer).to receive(:call) do
            progress.call('Recomputing swimmer categories', 1, 10)
            raise StandardError, 'recompute exploded'
          end
        end
      end
      post(recompute_source_categories_path(file_path: source_path))
      expect(response).to redirect_to(review_sessions_path(file_path: source_path, phase_v2: 1))
      expect(flash[:error]).to eq(I18n.t('data_import.errors.category_recompute_failed'))
      op = broadcasts.first[:op]
      expect(broadcasts).to eq([{ op:, seq: 1, scope: basename, msg: 'Recomputing swimmer categories', progress: 1, total: 10 },
                                { op:, state: 'done' }])
    end
  end
end
