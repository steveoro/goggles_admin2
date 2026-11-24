# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ops::RestoreRun do
  include ActiveSupport::Testing::TimeHelpers

  after(:each) { Ops::Database.reset_state! }

  it 'validates the status and the mode' do
    expect(described_class.new(status: 'whatever')).not_to be_valid
    expect(described_class.new(status: 'ready', mode: 'other')).not_to be_valid
    expect(create_restore_run).to be_valid
  end

  it 'tells the locking, terminal and preparing statuses apart' do
    expect(described_class::LOCKING_STATUSES).to eq(%w[confirmed loading post_steps interrupted])
    expect(create_restore_run(status: 'interrupted')).to be_locking
    expect(create_restore_run(status: 'finished')).to be_terminal
    expect(create_restore_run(status: 'snapshotting')).to be_preparing
  end

  it 'checks the progress token by its digest only' do
    run = create_restore_run
    token = run.issue_token!
    expect(run.progress_token_digest).to eq(Digest::SHA256.hexdigest(token))
    expect(run.progress_token_digest).not_to include(token)
    expect(run.token_matches?(token)).to be(true)
    expect(run.token_matches?('nope')).to be(false)
    expect(run.token_matches?(nil)).to be(false)
  end

  it 'claims a status move once' do
    run = create_restore_run(status: 'confirmed')
    expect(run.claim!(from: 'confirmed', to: 'loading', job_id: 'a')).to be(true)
    expect(run.claim!(from: 'confirmed', to: 'loading', job_id: 'b')).to be(false)
    expect(run.reload).to have_attributes(status: 'loading', job_id: 'a')
  end

  it 'is stalled after STALLED_AFTER without a heartbeat (not while awaiting a terminal load)' do
    run = create_restore_run(status: 'loading')
    expect(run).not_to be_stalled
    travel(described_class::STALLED_AFTER + 1.second) do
      expect(run).to be_stalled
      expect(run).to be_needs_operator
      run.update_columns(step: described_class::AWAITING_TERMINAL) # rubocop:disable Rails/SkipsModelValidations
      expect(run).not_to be_stalled
    end
  end

  it 'keeps only the newest LOG_LIMIT bytes of the log' do
    run = create_restore_run
    stub_const("#{described_class}::LOG_LIMIT", 120)
    5.times { |index| run.append_log!("line #{index} #{'x' * 30}") }
    expect(run.log.bytesize).to be <= 120
    expect(run.log).to include('line 4')
    expect(run.log).not_to include('line 0')
  end

  it "drops the operator's API token on every terminal status and hides 'preserved' from inspect" do
    run = create_restore_run(status: 'interrupted', preserved: { 'jwt' => 'eyJa.eyJb.c1', 'api_url' => 'x' })
    expect(run.preserved).to have_key('jwt')
    expect(run.inspect).not_to include('eyJa')
    run.update!(status: 'cancelled')
    expect(run.reload.preserved).not_to have_key('jwt')
    expect(run.preserved).to include('api_url' => 'x', 'jwt_dropped_at' => be_present)
  end

  it 'scrubs API tokens from the error and the log' do
    run = create_restore_run(preserved: { 'jwt' => 'opaque-secret' })
    run.update!(error_text: 'failed with opaque-secret and eyJhbGciOi.eyJ1c2VyX2lkIjoxfQ.sig_part')
    run.append_log!('again opaque-secret')
    expect([run.error, run.log].join).not_to include('opaque-secret', 'eyJhbGciOi')
  end

  it 'computes the load progress' do
    expect(create_restore_run(dump_bytes: 200, progress_bytes: 50).progress_percent).to eq(25.0)
    expect(create_restore_run(dump_bytes: nil).progress_percent).to be_nil
  end
end
