# frozen_string_literal: true

require 'rails_helper'

# The guided restore pages poll their run's JSON status (db_restore_controller.js) and reload when it changes:
# no Action Cable, since the progress page must keep working while MySQL is dropped and reloaded. These examples
# change the run in the ops DB, as the jobs do, and expect the open page to follow by itself.
RSpec.describe 'Guided DB restore pages' do
  before(:each) { sign_in_admin(prepare_admin_user) }

  it 'shows the outcome of the dump inspection by itself when the inspection job ends' do
    run = create_restore_run(status: 'inspecting', step: 'inspect')
    visit(inspect_db_restore_path(run))
    expect(page).to have_css('#db-restore-inspecting')

    run.update!(status: 'failed', step: 'inspect_failed', inspection: { 'errors' => [{ 'code' => 'no_schema_version' }] },
                finished_at: Time.current)
    expect(page).to have_css('#db-restore-inspect-failed', wait: 10)
    expect(page).to have_no_css('#db-restore-inspecting')
    expect_no_js_errors
  end

  it 'follows the steps of a running restore on the progress page' do
    run = lock_with_run(status: 'loading', step: 'load')
    visit(db_restore_path(run, token: run.issue_token!))
    expect(page).to have_css('#db-restore-status', text: I18n.t('db_restore.statuses.loading'))

    run.update!(status: 'post_steps', step: 'post_steps')
    expect(page).to have_css('#db-restore-status', text: I18n.t('db_restore.statuses.post_steps'), wait: 10)
  ensure
    DbRestore::Lock.release!(run) if run
  end
end
