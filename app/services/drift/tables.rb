# frozen_string_literal: true

module Drift
  #
  # = Drift::Tables
  #
  # The tables compared by the DB sync check: the fixed whitelist of the API endpoint 'tools/db_fingerprint'
  # (import-owned and user-touched tables), with their owner class:
  # - :import => written on production only by the SQL scripts pushed from here (and by admins);
  # - :user   => also written by the goggles_main users (sign-ups, chrono recordings, team managers, ...).
  #
  # COMMIT_TABLES are the tables Import::Committers::Main inserts into (Phase 6 commit, explicit ids): a remote
  # max id above the local one there means the next commit or push may collide (red verdict).
  #
  module Tables
    OWNERS = {
      'meetings' => :import, 'meeting_sessions' => :import, 'meeting_events' => :import, 'meeting_programs' => :import,
      'meeting_individual_results' => :user, 'meeting_relay_results' => :user, 'meeting_relay_swimmers' => :user,
      'laps' => :user, 'relay_laps' => :user, 'meeting_team_scores' => :import, 'swimmers' => :user, 'teams' => :user,
      'team_affiliations' => :user, 'badges' => :user, 'calendars' => :import, 'swimming_pools' => :user,
      'cities' => :user, 'managed_affiliations' => :user, 'standard_timings' => :import, 'category_types' => :import,
      'users' => :user
    }.freeze

    # Tables Import::Committers::Main (app/strategies/import/committers/*) inserts into.
    COMMIT_TABLES = %w[
      meetings meeting_sessions meeting_events meeting_programs meeting_individual_results meeting_relay_results
      meeting_relay_swimmers laps relay_laps meeting_team_scores swimmers teams team_affiliations badges calendars
      swimming_pools cities
    ].freeze

    module_function

    # Whitelisted table names, in display order.
    def all
      OWNERS.keys
    end

    # :import or :user (nil for a table outside the whitelist).
    def owner(table)
      OWNERS[table.to_s]
    end

    def import_owned?(table) = owner(table) == :import
    def commit_table?(table) = COMMIT_TABLES.include?(table.to_s)
    def whitelisted?(table) = OWNERS.key?(table.to_s)

    # The whitelisted subset of +tables+ (whitelist order), or every table when +tables+ is blank.
    def normalize(tables)
      list = Array(tables).flat_map { |name| name.to_s.split(',') }.map(&:strip).compact_blank
      return all if list.empty?

      all & list
    end
  end
end
