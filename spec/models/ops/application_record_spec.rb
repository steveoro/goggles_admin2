# frozen_string_literal: true

require 'rails_helper'
require 'open3'

RSpec.describe Ops::ApplicationRecord do
  it 'is abstract and connected to the ops DB' do
    expect(described_class).to be_abstract_class
    expect(described_class.connection_db_config.name).to eq('ops')
    expect(described_class.connection_db_config.database).to eq('db/ops/test.sqlite3')
  end

  # Boots (and eager-loads) the app in a child process, using a copy of config/database.yml
  # without any 'ops:' entry.
  describe 'boot without the ops entry' do
    let(:tmp_dir) { Dir.mktmpdir('ops-boot') }
    let(:db_yml) { File.join(tmp_dir, 'database.yml') }
    let(:script) do
      <<~RUBY
        require #{Rails.root.join('config/application').to_s.inspect}
        Rails.application.config.paths['config/database'] = ENV.fetch('OPS_SPEC_DATABASE_YML')
        Rails.application.initialize!
        Rails.application.eager_load!
        Zeitwerk::Loader.eager_load_all
        query = begin
          Ops::Event.count
        rescue Ops::NotConfiguredError => e
          e.class.name
        end
        puts({ state: Ops.state, event: Ops.record_event!(kind: 'spec.boot'), query:,
               rebuilders: Ops::Rebuilders.names }.inspect)
      RUBY
    end

    after(:each) { FileUtils.rm_rf(tmp_dir) }

    # Drops every "  ops:" block (and its indented lines) from the YAML text.
    def without_ops_entries(yaml)
      skipping = false
      yaml.lines.reject do |line|
        skipping = true if line.start_with?('  ops:')
        skipping = false if skipping && !line.start_with?('  ops:') && !line.start_with?('    ') && line.strip.present?
        skipping
      end.join
    end

    it 'still boots, reporting :not_configured and skipping the event writes' do
      File.write(db_yml, without_ops_entries(Rails.root.join('config/database.yml').read))
      expect(File.read(db_yml)).not_to include('db/ops/')

      out, err, status = Bundler.with_original_env do
        Open3.capture3({ 'RAILS_ENV' => 'test', 'OPS_SPEC_DATABASE_YML' => db_yml },
                       'bundle', 'exec', 'ruby', '-e', script, chdir: Rails.root.to_s)
      end
      expect(status).to be_success, "child boot failed:\n#{err.lines.last(20).join}"
      expect(out.lines.last.strip).to eq(
        # (the rebuilders registered at boot are only names: nothing runs while the ops DB is not configured)
        { state: :not_configured, event: nil, query: 'Ops::NotConfiguredError', rebuilders: [:outbox] }.inspect
      )
    end
  end
end
