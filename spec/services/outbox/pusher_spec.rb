# frozen_string_literal: true

require 'rails_helper'

# APIProxy is stubbed in every example: nothing is ever posted.
RSpec.describe Outbox::Pusher do
  include AdminSignInHelpers

  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:user) { prepare_admin_user }
  let(:api_url) { 'http://localhost:8081' }
  let(:ping) { APIProxy::Result.new(DummyResponse.new(body: { msg: 'OK', version: '7.0.1' }.to_json)) }
  let(:scripts) do
    [
      create_sql_script(data_root, 'results.new/262/0010-a-lt4.sql', content: 'SELECT 1;'),
      create_sql_script(data_root, 'results.new/misc/0011-merge_teams-1-2.sql', content: 'SELECT 2;'),
      create_sql_script(data_root, 'results.new/262/0012-calendar_link-1-2.sql', content: 'SELECT 3;')
    ]
  end
  let(:run) do
    Ops::PushRun.create!(user_id: user.id, target_api_url: api_url, target_env: 'unknown', script_ids: scripts.map(&:id),
                         status: 'running', started_at: Time.current)
  end

  def accepted(id)
    APIProxy::Result.new(DummyResponse.new(body: { msg: 'OK', new: { id: } }.to_json))
  end

  def rejected(detail)
    response = instance_double(RestClient::Response, code: 422, body: { 'error' => 'Unprocessable' }.to_json,
                                                     headers: { x_error_detail: detail })
    APIProxy::Result.new(response)
  end

  def unreachable
    APIProxy::Result.new(APIProxy::UnreachableResponse.new(api_url, Errno::ECONNREFUSED.new))
  end

  def push!
    described_class.new(run:, data_root:).call
  end

  before(:each) { allow(APIProxy).to receive(:ping).and_return(ping) }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'stops at the first rejected script: the first is sent and moved, the second pending with its error, the third untouched' do
    allow(APIProxy).to receive(:call).and_return(accepted(501), rejected('Validation failed: data_file'))

    push!

    first, second, third = scripts.map(&:reload)
    expect(first).to have_attributes(state: 'sent', remote_iq_id: 501, target_api_url: api_url, target_env: 'unknown',
                                     rel_path: 'results.sent/262/0010-a-lt4.sql', push_attempts: 1)
    expect(first.pushed_at).to be_present
    expect(data_root.join('results.sent/262/0010-a-lt4.sql')).to exist
    expect(data_root.join('results.new/262/0010-a-lt4.sql')).not_to exist
    expect(second).to have_attributes(state: 'pending', last_error: 'Validation failed: data_file', push_attempts: 1)
    expect(third).to have_attributes(state: 'pending', push_attempts: 0)
    expect(run.reload).to have_attributes(status: 'stopped', pushed_count: 1, stopped_at_script_id: second.id)
    expect(APIProxy).to have_received(:call).twice
  end

  it 'posts each script file to import_queue/batch_sql of the run target with the user JWT' do
    allow(APIProxy).to receive(:call).and_return(accepted(1), accepted(2), accepted(3))
    push!
    expect(APIProxy).to have_received(:call)
      .with(hash_including(method: :post, url: 'import_queue/batch_sql', jwt: user.jwt, base_url: api_url)).exactly(3).times
    expect(run.reload).to have_attributes(status: 'finished', pushed_count: 3)
    expect(Ops::SqlScript.sent.count).to eq(3)
    expect(Ops::Event.where(kind: 'push.uploaded').count).to eq(3)
  end

  it 'keeps a lower pending seq blocking a single push unless held or overridden' do
    allow(APIProxy).to receive(:call).and_return(accepted(9))
    run.update!(script_ids: [scripts.second.id])
    push!
    expect(run.reload).to have_attributes(status: 'stopped')
    expect(run.error).to include('0010-a-lt4.sql')
    expect(APIProxy).not_to have_received(:call)

    scripts.first.hold!
    run.update!(status: 'running', error: nil)
    push!
    expect(scripts.second.reload).to be_sent
  end

  it 'pushes out of order with the explicit override' do
    allow(APIProxy).to receive(:call).and_return(accepted(9))
    run.update!(script_ids: [scripts.second.id], override_order: true)
    push!
    expect(scripts.second.reload).to be_sent
    expect(scripts.first.reload).to be_pending
  end

  it 'stops when a file changed since it was registered' do
    allow(APIProxy).to receive(:call)
    File.write(scripts.first.absolute_path, 'SELECT 99;')
    run # (the Reconciler would re-hash a pending edit: keep the stat unchanged to simulate an edit it missed)
    allow(Outbox::Reconciler).to receive(:call)
    push!
    expect(run.reload).to have_attributes(status: 'stopped')
    expect(run.error).to include(scripts.first.sha256.first(12))
    expect(APIProxy).not_to have_received(:call)
  end

  it 'aborts before the first POST when the target is unreachable' do
    allow(APIProxy).to receive(:ping).and_return(unreachable)
    allow(APIProxy).to receive(:call)
    push!
    expect(run.reload).to have_attributes(status: 'aborted')
    expect(APIProxy).not_to have_received(:call)
    expect(scripts.map { |script| script.reload.state }.uniq).to eq(['pending'])
  end

  it 'aborts before the first POST when the user JWT is expired' do
    user.update!(jwt: 'expired-or-forged')
    allow(APIProxy).to receive(:call)
    push!
    expect(run.reload).to have_attributes(status: 'aborted')
    expect(APIProxy).not_to have_received(:call)
  end

  it 'puts an unreachable POST back to pending and stops the run' do
    allow(APIProxy).to receive(:call).and_return(unreachable)
    push!
    expect(scripts.first.reload).to have_attributes(state: 'pending')
    expect(scripts.first.last_error).to include('API unreachable')
    expect(run.reload).to be_stopped
  end

  it 'turns a pushing row left by an older run into in_doubt and never re-posts it' do
    scripts.first.update!(state: 'pushing')
    allow(APIProxy).to receive(:call).and_return(accepted(5))
    push!
    expect(scripts.first.reload).to be_in_doubt
    expect(run.reload).to be_stopped # (the in-doubt script blocks the next ones)
    expect(APIProxy).not_to have_received(:call)
  end
end
