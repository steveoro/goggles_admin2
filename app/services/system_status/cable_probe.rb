# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::CableProbe
  #
  # Live updates (ActionCable on Solid Cable, see config/cable.yml): is the 'cable' database configured for this
  # environment, its SQLite file present and its messages table created? Read inline; never creates the DB file.
  #
  # Levels: :ok ready; :warn not configured or not prepared: the broadcasts of the jobs (Season board pings, FIN
  # alerts) don't reach the pages, which fall back to polling (e.g. every 20 s while something runs).
  #
  class CableProbe < Probe
    # True when the Solid Cable messages table exists (call only once the database file is known to exist).
    def self.messages_table?
      SolidCable::Message.table_exists?
    end

    protected

    def evaluate
      return result(:warn, detail: detail_text(:other_adapter, adapter: adapter)) unless adapter == 'solid_cable'

      db_config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: 'cable')
      return result(:warn, detail: detail_text(:not_configured)) if db_config.nil?
      return result(:warn, detail: detail_text(:not_prepared)) unless database_present?(db_config) && self.class.messages_table?

      result(:ok, detail: detail_text(:ok), checked_at: now)
    end

    private

    def adapter
      @adapter ||= ActionCable.server.config.cable&.fetch('adapter', nil).to_s
    end

    # SQLite: the file must exist (connecting would create it); other adapters: assumed present.
    def database_present?(db_config)
      return true unless db_config.adapter.to_s.include?('sqlite')

      Rails.root.join(db_config.database.to_s).exist?
    end
  end
end
