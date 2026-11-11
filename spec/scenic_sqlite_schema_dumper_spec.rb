# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScenicSqliteSchemaDumper do
  it 'dumps support tables without querying MySQL views' do
    config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
      'test', 'sqlite_dump_probe', { 'adapter' => 'sqlite3', 'database' => ':memory:' }
    )

    ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |connection|
      connection.create_table(:schema_dump_probe) { |table| table.string :label }
      stream = StringIO.new

      ActiveRecord::SchemaDumper.dump(connection.pool, stream)

      expect(stream.string).to include('create_table "schema_dump_probe"')
    end
  end
end
