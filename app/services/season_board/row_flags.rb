# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::RowFlags
  #
  # Computes the informational flags of a Season board row (Row#flags):
  #
  # - :busy                         crawl/extraction queued or running (ActivityLog)
  # - :crawl_failed/:extract_failed latest attempt of that kind failed
  # - :manifest_pdf_pending         a manifest PDF is pending but the state doesn't ask to extract it
  #                                 (e.g. the meeting is already linked)
  # - :redundant_result_free_source a result-free crawl output sits in results.new for an already linked meeting
  # - :missing_meeting              the calendar points to a meeting id that doesn't exist
  # - :duplicate_calendar           more than one season calendar has this FIN id
  # - :multiple_sources             more than one source base is pending in results.new
  # - :pushed                       at least one SQL batch for the FIN id is in results.sent
  # - :outside_season               the row dates fall outside the season begin/end dates
  # - :unparsable_date              the row date text couldn't be parsed
  # - :possible_unlinked_meeting    :link_not_crawled row whose dates include the date of a link candidate
  #                                 calendar (no FIN id yet): a local meeting (e.g. imported from FICR) may
  #                                 just need linking; automatic crawls skip these rows
  #
  class RowFlags
    FLAGS = %i[
      busy crawl_failed extract_failed manifest_pdf_pending redundant_result_free_source missing_meeting
      duplicate_calendar multiple_sources pushed outside_season unparsable_date possible_unlinked_meeting
    ].freeze

    def initialize(season:, db_index:)
      @season = season
      @db_index = db_index
    end

    # FIN ids used by more than one season calendar (Set, memoized).
    def duplicate_fin_event_ids
      @duplicate_fin_event_ids ||= @db_index.duplicate_fin_event_ids.to_set
    end

    # Returns the Array of flags (Symbols, in FLAGS order) for the row facts
    # (StateResolver::Facts), its resolved state, its activity Hash & busy overlay.
    # +unlinked_dates+: dates (Date) of the season link candidate calendars (Builder.link_candidates).
    def call(facts, state, activity, busy, unlinked_dates: [])
      flags = {
        busy: busy,
        possible_unlinked_meeting: state == :link_not_crawled && unlinked_date_within?(facts.row_date, unlinked_dates),
        crawl_failed: activity[:crawl]&.failed?,
        extract_failed: activity[:extract]&.failed?,
        unparsable_date: !facts.row_date.valid?,
        outside_season: facts.row_date.valid? && !within_season?(facts.row_date)
      }.merge(link_flags(facts), disk_flags(facts.disk, facts.meeting, state))
      FLAGS.select { |flag| flags[flag] }
    end

    private

    def link_flags(facts)
      {
        missing_meeting: facts.calendar&.meeting_id && facts.meeting.nil?,
        duplicate_calendar: facts.fin_event_id && duplicate_fin_event_ids.include?(facts.fin_event_id)
      }
    end

    def disk_flags(disk, meeting, state)
      return {} unless disk

      {
        manifest_pdf_pending: disk.manifest_pending? && state != :manifest_pending,
        redundant_result_free_source: meeting && disk.result_free_source,
        multiple_sources: disk.sources.many?(&:files?),
        pushed: disk.sql_sent_paths.any?
      }
    end

    def unlinked_date_within?(row_date, dates)
      row_date.valid? && dates.any? { |date| date.between?(row_date.first_date, row_date.last_date) }
    end

    def within_season?(row_date)
      return true if @season.begin_date.blank? || @season.end_date.blank?

      row_date.first_date >= @season.begin_date && row_date.last_date <= @season.end_date
    end
  end
end
