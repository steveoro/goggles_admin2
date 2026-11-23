# frozen_string_literal: true

# Helpers for the data health specs (spec/services/health, spec/jobs/health, spec/requests/health).
module HealthSpecHelpers
  # A Health::SeasonScope::Entry for +season+ with the given status (:closed, :current, :upcoming).
  def health_entry(season, status:, meetings_count: 1, badges_count: 1)
    Health::SeasonScope::Entry.new(season_id: season.id, description: season.description, begin_date: season.begin_date,
                                   end_date: season.end_date, status:, meetings_count:, badges_count:)
  end

  # A closed season (ended last year).
  def closed_health_season
    FactoryBot.create(:season, begin_date: Date.current - 2.years, end_date: Date.current - 1.year)
  end

  def health_session(meeting)
    FactoryBot.create(:meeting_session, meeting:)
  end

  # An individual event (with a program) for +meeting+; returns the program.
  def health_individual_program(meeting)
    event = FactoryBot.create(:meeting_event_individual, meeting_session: health_session(meeting))
    FactoryBot.create(:meeting_program_individual, meeting_event: event)
  end

  # Adds one MIR to +meeting+ (new session, event and program); returns it.
  def health_add_mir(meeting, **attributes)
    FactoryBot.create(:meeting_individual_result, meeting_program: health_individual_program(meeting), **attributes)
  end

  # Adds one MRR to +meeting+ (new session, relay event and program); returns it.
  def health_add_mrr(meeting)
    event = FactoryBot.create(:meeting_event_relay, meeting_session: health_session(meeting))
    FactoryBot.create(:meeting_relay_result, meeting_program: FactoryBot.create(:meeting_program_relay, meeting_event: event))
  end

  # Statements that write (transaction control statements like SAVEPOINT / RELEASE never match).
  WRITE_SQL_REGEXP = /\A\s*(INSERT|UPDATE|DELETE|REPLACE|TRUNCATE|ALTER|CREATE|DROP)/i

  # Subscribes to 'sql.active_record' while the block runs; returns every SQL statement run on the primary DB.
  def primary_db_statements(&)
    statements = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      connection = payload[:connection]
      next unless connection.respond_to?(:pool) && connection.pool.db_config.name == 'primary'

      statements << payload[:sql].to_s
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    statements
  end
end

RSpec.configure do |config|
  config.include(HealthSpecHelpers)
end
