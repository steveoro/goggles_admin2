# frozen_string_literal: true

# Ops DB (db/ops/<env>.sqlite3): log of the API calls that may have changed the remote data
# (every APIProxy.call but GET, the sign-in and the SQL batch push; see Ops::RemoteWrite).
# Payload keys only: values and headers are never stored.
class CreateRemoteWrites < ActiveRecord::Migration[8.1]
  def change
    create_table :remote_writes do |t|
      t.string :http_method, null: false
      t.string :endpoint, null: false
      t.string :base_url, null: false
      t.integer :status_code
      t.boolean :unreachable, null: false, default: false
      t.string :error_detail, limit: 300
      t.json :payload_keys, null: false, default: []
      t.integer :user_id
      t.string :source
      t.datetime :created_at, null: false

      t.index :created_at
      t.index %i[endpoint created_at]
      t.index %i[base_url created_at]
    end
  end
end
