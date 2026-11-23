# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Outbox::PushJob do
  include AdminSignInHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:data_root) { Pathname.new(Dir.mktmpdir) }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'runs on the outbox queue, one at a time' do
    expect(described_class.new.queue_name).to eq('outbox')
    expect(described_class.concurrency_limit).to eq(1)
    expect(described_class.new(1).concurrency_key).to include('outbox_push')
    expect(described_class.concurrency_duration).to eq(2.hours)
  end

  it 'is enqueued only by OutboxController (an operator click): no scheduler, planner, callback or other job' do
    callers = Rails.root.glob('app/**/*.rb').select { |path| path.read.match?(/Outbox::PushJob\s*\.\s*(perform_later|perform_now|set)\b/) }
    expect(callers.map { |path| path.relative_path_from(Rails.root).to_s }).to eq(['app/controllers/outbox_controller.rb'])
    recurring = YAML.safe_load(ERB.new(Rails.root.join('config/recurring.yml').read).result, aliases: true)
    expect(recurring.to_s).not_to include('Outbox::PushJob')
  end

  it 'never retries: an unexpected error stops the run and the job is discarded' do
    run = Ops::PushRun.create!(user_id: 1, script_ids: [], status: 'running', started_at: Time.current)
    allow(Outbox::Pusher).to receive(:new).and_raise(RuntimeError, 'boom')

    expect { described_class.perform_now(run.id) }.not_to have_enqueued_job(described_class)
    expect(run.reload).to have_attributes(status: 'stopped')
    expect(run.error).to include('boom')
  end

  it 'does nothing for a run that is not running' do
    run = Ops::PushRun.create!(user_id: 1, script_ids: [], status: 'finished', started_at: Time.current)
    allow(Outbox::Pusher).to receive(:new)
    described_class.perform_now(run.id)
    expect(Outbox::Pusher).not_to have_received(:new)
  end

  it 'turns a stale pushing script into in_doubt and never re-posts it' do
    user = prepare_admin_user
    allow(Outbox).to receive(:data_root).and_return(data_root)
    stale = create_sql_script(data_root, 'results.new/262/0010-a-lt4.sql', state: 'pushing')
    travel_to(11.minutes.from_now) do
      # (the DB sync warning of an API without fingerprints was ticked on the confirmation page)
      run = Ops::PushRun.create!(user_id: user.id, target_api_url: 'http://localhost:8081', target_env: 'unknown',
                                 script_ids: [stale.id], status: 'running', started_at: Time.current, drift_acknowledged: true)
      allow(APIProxy).to receive_messages(ping: APIProxy::Result.new(DummyResponse.new(body: '{"msg":"OK"}')), call: nil)
      described_class.perform_now(run.id)
      expect(stale.reload).to be_in_doubt
      expect(APIProxy).not_to have_received(:call)
      expect(run.reload).to be_stopped
    end
  end
end
