# frozen_string_literal: true

module Sources
  #
  # = Sources::CrawlRequest
  #
  # One manual crawl of the Sources crawler tab, validated twice: by Sources::CrawlsController before queuing
  # SourceCrawlJob, and again by the job before calling the crawler (the job arguments are never trusted as given).
  #
  # == Attributes
  # - kind: one of Sources::CrawlKinds::KINDS; season_id: Integer;
  # - url: meeting URL (URL kinds); target_event: optional Microplus event title;
  # - file_path: calendar CSV (calendar_results), inside 'calendar.new/<season>' (real path);
  # - sub_menu_type / year_text: FIN calendar menu item and season text (calendar).
  #
  # #errors lists the i18n keys ('sources.crawl.errors.<key>') of the problems (empty when valid).
  #
  CrawlRequest = Data.define(:kind, :season_id, :url, :file_path, :target_event, :sub_menu_type, :year_text) do
    # Builds the request from params or job arguments (String or Symbol keys; blank values as nil).
    def self.from(values)
      hash = values.to_h.symbolize_keys
      new(kind: hash[:kind].to_s, season_id: hash[:season_id].to_i, url: hash[:url].to_s.strip.presence,
          file_path: hash[:file_path].to_s.presence, target_event: hash[:target_event].to_s.strip.presence,
          sub_menu_type: hash[:sub_menu_type].to_s.presence, year_text: hash[:year_text].to_s.strip.presence)
    end

    # The default 'Eventi' calendar crawl of a season (0.10.103): the request of the crawler tab's FIN calendar form left
    # on its defaults (first sub-menu item, the season text of the season), so a manual crawl and an automatic one
    # (SeasonBoard::Scheduler.calendar_crawl!) share the same ActivityLog key and never run twice.
    def self.eventi_calendar(season)
      new(kind: 'calendar', season_id: season.id.to_i, url: nil, file_path: nil, target_event: nil,
          sub_menu_type: CrawlKinds::CALENDAR_SUB_MENUS.first, year_text: CrawlKinds.year_text_for(season))
    end

    def valid?(guard: FileGuard.new) = errors(guard:).empty?

    # i18n keys of the problems (Array of Symbols).
    def errors(guard: FileGuard.new)
      return [:unknown_kind] unless CrawlKinds::KINDS.include?(kind)
      return [:unknown_season] unless season_id.positive? && GogglesDb::Season.exists?(id: season_id)

      case kind
      when 'calendar' then calendar_errors
      when 'calendar_results' then calendar_file?(guard) ? [] : [:invalid_calendar_file]
      else CrawlKinds.valid_url?(kind, url) ? [] : [:"invalid_url_#{kind}"]
      end
    end

    # What is crawled (URL, calendar file or calendar selection), part of the ActivityLog key.
    def target
      case kind
      when 'calendar' then "#{season_id}|#{sub_menu_type}|#{year_text}"
      when 'calendar_results' then file_path.to_s
      else url.to_s
      end
    end

    # SeasonBoard::ActivityLog key of the crawl ('src:<sha1>').
    def key = SeasonBoard::ActivityLog.source_key("crawl:#{kind}", target)

    # Short label shown by the activity strip and the "In progress" zone.
    def label
      detail = case kind
               when 'calendar' then [year_text, sub_menu_type].compact.join(' · ')
               when 'calendar_results' then File.basename(file_path.to_s)
               else url.to_s.sub(%r{\Ahttps?://}i, '').truncate(60)
               end
      I18n.t("sources.crawl.labels.#{kind}", detail:, default: detail)
    end

    def fin_server? = CrawlKinds::FIN_KINDS.include?(kind)

    # Number of meetings of the run (the rows of a calendar CSV, else 1).
    def meeting_count
      return 1 unless kind == 'calendar_results' && file_path && File.file?(file_path)

      [CrawlerCalendar::Sheet.new(file_path, season_id:).row_count, 1].max
    rescue StandardError
      1
    end

    # Hard timeout of the run: 30 minutes per meeting, at most 12 hours (CrawlKinds::TIMEOUT_PER_MEETING, MAX_TIMEOUT).
    def timeout
      [CrawlKinds::TIMEOUT_PER_MEETING * meeting_count, CrawlKinds::MAX_TIMEOUT].min
    end

    # SourceCrawlJob arguments (only the members of the kind).
    def to_job_args
      { kind:, season_id:, url:, file_path:, target_event:, sub_menu_type:, year_text: }.compact
    end

    # Starts the crawl through the CrawlerClient; returns its CrawlerClient::Result.
    def start!(client)
      case kind
      when 'calendar'
        client.pull_calendar(season_id:, start_url: CrawlKinds::FIN_CALENDAR_BASE_URL, sub_menu_type:, year_text:)
      when 'calendar_results'
        client.pull_results_from_file(season_id:, file_path:, layout: CrawlKinds.result_layout_for(season_id))
      when 'fin_meeting' then client.pull_meeting(season_id:, url:)
      when 'microplus' then client.pull_microplus(season_id:, url:, target_event:)
      when 'ficr' then client.pull_ficr(season_id:, url:)
      when 'goandswim' then client.pull_goandswim(season_id:, url:)
      end
    end

    private

    def calendar_errors
      problems = []
      problems << :invalid_sub_menu unless CrawlKinds::CALENDAR_SUB_MENUS.include?(sub_menu_type)
      problems << :invalid_year_text unless year_text.to_s.match?(%r{\A\d{4}/\d{4}\z})
      problems
    end

    # True for an existing .csv file inside 'calendar.new/<season>' (the folder the results crawler consumes).
    def calendar_file?(guard)
      real = guard.resolve!(file_path)
      real.extname.casecmp?('.csv') && real.dirname == guard.root.join('calendar.new', season_id.to_s)
    rescue FileGuard::Refused, SystemCallError
      false
    end
  end
end
