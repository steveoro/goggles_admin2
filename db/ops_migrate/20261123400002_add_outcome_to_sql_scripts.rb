# frozen_string_literal: true

# Ops DB: the remote outcome of a pushed SQL script (phase 08). The Main app now reports it in the import queue
# row ('applied' or 'failed' with the MariaDB error text), read by Outbox::RemoteStatusJob; Withdraw deletes a
# queued row on the server (see Ops::SqlScript, Outbox::RemoteActions).
class AddOutcomeToSqlScripts < ActiveRecord::Migration[8.1]
  def change
    change_table :sql_scripts, bulk: true do |t|
      t.datetime :remote_outcome_at
      t.text :remote_error
      t.datetime :withdrawn_at
    end
  end
end
