# frozen_string_literal: true

#
# = Ops
#
# Entry point for the local SQLite "ops" DB (<tt>db/ops/<env>.sqlite3</tt>, entry <tt>ops:</tt> in
# config/database.yml), which stores the admin2-only data (event log, settings, snapshots, ...).
# The DB itself is handled by Ops::Database; its models inherit from Ops::ApplicationRecord.
#
# Every caller outside the rake tasks should go through these helpers: when the DB is not
# configured, missing or not migrated, they degrade to no-ops instead of raising.
#
# == Usage
#   Ops.available?   # => true only when the DB is ready (never creates the file)
#   Ops.state        # => :not_configured | :missing | :needs_migration | :ready
#   Ops.safely([]) { Ops::Event.recent.to_a }
#   Ops.record_event!(kind: 'datafix.committed', level: 'success', actor: 'operator', season_id: 242,
#                     subject_type: 'source', subject_key: 'path/to/file-lt4.json', data: { sql: '0001-file-lt4.sql' })
#
module Ops
  # Raised by the Ops models when the 'ops' DB entry is missing from config/database.yml.
  class NotConfiguredError < StandardError; end

  EVENT_LEVELS = %w[info success warning error].freeze
  EVENT_ACTORS = %w[operator job system].freeze

  # True only when the ops DB is ready (state == :ready). Never creates the DB file.
  def self.available?
    state == :ready
  end

  # Returns one of Ops::Database::STATES.
  def self.state
    Ops::Database.state
  end

  # Yields and returns the block value; on any StandardError logs a warning and returns +default+.
  # A busy SQLite DB (ActiveRecord::StatementTimeout) is retried once.
  def self.safely(default = nil)
    retried = false
    begin
      yield
    rescue ActiveRecord::StatementTimeout => e
      unless retried
        retried = true
        retry
      end
      log_failure(e)
      default
    rescue StandardError => e
      log_failure(e)
      default
    end
  end

  # Appends a row to the event log (Ops::Event). Never raises: returns the created Ops::Event,
  # or nil when the ops DB is not available or the write fails.
  #
  # == Params
  # - kind: dotted event kind (i18n key 'ops.events.<kind>'), e.g. 'datafix.committed';
  # - level: one of EVENT_LEVELS; actor: one of EVENT_ACTORS;
  # - season_id: optional MySQL Season ID;
  # - subject_type, subject_key: optional subject reference (e.g. 'source' + file path, 'fin_event' + FIN ID);
  # - data: JSON-able Hash of details; link_path: optional app path related to the event.
  #
  # rubocop:disable-next Metrics/ParameterLists
  def self.record_event!(kind:, level: 'info', actor: 'system', season_id: nil,
                         subject_type: nil, subject_key: nil, data: {}, link_path: nil)
    safely do
      next unless available?

      Ops::Event.create!(
        occurred_at: Time.current, kind: kind.to_s, level: level.to_s, actor: actor.to_s,
        season_id:, subject_type:, subject_key: subject_key&.to_s, data: data || {}, link_path:
      )
    end
  end

  def self.log_failure(error)
    Rails.logger.warn("[Ops] #{error.class}: #{error.message}")
  end
  private_class_method :log_failure
end
