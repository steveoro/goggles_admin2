# frozen_string_literal: true

require 'rails_helper'

# Phase 14: the click-only jobs are also refused at enqueue while the restore lock is held (DbRestoreGuard answers
# first; these are the actions' own checks, for a lock taken between the guard and the enqueue).
RSpec.describe 'Enqueue refusals while a DB restore holds the lock' do
  include AdminSignInHelpers
  include ActiveJob::TestHelper

  let(:admin_user) { prepare_admin_user }

  after(:each) { Ops::Database.reset_state! }

  describe 'POST /outbox/push' do
    before(:each) do
      sign_in_admin(admin_user)
      allow_any_instance_of(OutboxController).to receive(:db_restore_guard) # rubocop:disable RSpec/AnyInstance
      lock_with_run
    end

    it 'redirects with the "restore in progress" flash, without creating a push run or a job' do
      post(outbox_push_path, params: { confirmed: '1', scope: 'all_pending' })
      expect(response).to redirect_to(outbox_path)
      expect(flash[:alert]).to eq(I18n.t('db_restore.flash.locked'))
      expect(Ops::PushRun.count).to eq(0)
      expect(enqueued_jobs.pluck('job_class')).not_to include('Outbox::PushJob')
    end
  end

  describe DataFix::Guards do
    it 'blocks the Data-Fix commit (and prepare) with the real lock, naming the run' do
      run = lock_with_run
      %i[commit prepare].each do |scope|
        result = described_class.check(scope, acknowledged: true)
        expect(result).to be_block
        expect(result.verdict).to eq(:restore)
        expect(result.message).to include("run #{run.id}")
      end
    end

    it 'lets them through once the lock is released' do
      run = lock_with_run
      DbRestore::Lock.release!(run)
      result = described_class.check(:commit, acknowledged: true, gate: nil)
      expect(result).to be_ok
    end
  end
end
