# frozen_string_literal: true

module Sources
  #
  # = Sources::CrawlKinds
  #
  # The manual crawl kinds of the Sources crawler tab (SourceCrawlJob), with the base URLs and the URL checks that
  # used to live in the Pull page controller:
  #
  # - calendar:         the FIN calendar of a season (simulated click on a FIN sub-menu item) => calendar.new/<season>;
  # - calendar_results: every meeting of a calendar CSV in calendar.new/<season> (or a '-sel-' subset of it), with
  #                     the legacy result layouts 1 (seasons before 182) and 2;
  # - fin_meeting:      one FIN results page (layout 2, LT2 output);
  # - microplus, ficr, goandswim: one meeting of those timing sites (LT4 output).
  #
  # The URL kinds are checked against the host (and path shape) of their site: a placeholder or a URL of another
  # site is refused before anything is queued.
  #
  module CrawlKinds
    FIN_CALENDAR_BASE_URL = 'https://www.federnuoto.it/home/master.html'
    FIN_RESULTS_BASE_URL = 'https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/'
    MICROPLUS_RESULTS_BASE_URL = 'https://fin2025.microplustiming.com/'
    FICR_RESULTS_BASE_URL = 'https://nuoto.ficr.it/'
    GOANDSWIM_RESULTS_BASE_URL = 'https://risultati.goandswim.it/'

    # Sub-menu items of the FIN calendar page (the actual labels clicked by the crawler: left non-localized).
    CALENDAR_SUB_MENUS = ['Eventi', 'Riepilogo Eventi', 'Archivio 2012-'].freeze

    KINDS = %w[calendar calendar_results fin_meeting microplus ficr goandswim].freeze
    # Kinds taking a meeting URL (one free-form form each on the crawler tab).
    URL_KINDS = %w[fin_meeting microplus ficr goandswim].freeze
    # Kinds crawling the (slow, throttled) FIN server: the job pauses after them.
    FIN_KINDS = %w[calendar calendar_results fin_meeting].freeze

    # Hard timeout of one meeting crawl (the FIN server is slow and throttles: large championships take that long)
    # and of a whole run (a calendar CSV crawl: one timeout per meeting, capped).
    TIMEOUT_PER_MEETING = 30.minutes
    MAX_TIMEOUT = 12.hours

    # Example URL per URL kind (form placeholder).
    EXAMPLES = {
      'fin_meeting' => "#{FIN_RESULTS_BASE_URL}150091:distanze-speciali-campania-2026.html",
      'microplus' => "#{MICROPLUS_RESULTS_BASE_URL}MA_2025_06_24-29_Riccione.php",
      'ficr' => "#{FICR_RESULTS_BASE_URL}#/NUO/tempi/...",
      'goandswim' => "#{GOANDSWIM_RESULTS_BASE_URL}evento/5ce2d74fd05d4a659b511251caec6132"
    }.freeze

    # Site home pages linked below the URL forms.
    SITE_LINKS = {
      'fin_meeting' => FIN_CALENDAR_BASE_URL, 'microplus' => 'https://microplus.it/events/',
      'ficr' => FICR_RESULTS_BASE_URL, 'goandswim' => GOANDSWIM_RESULTS_BASE_URL
    }.freeze

    module_function

    # True when +url+ is a meeting URL of the +kind+ site (never raises).
    def valid_url?(kind, url) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity
      text = url.to_s.strip
      return false if text.empty? || text.match?(/\s|[<>]/) # (a '(+<LINK>)' placeholder or a pasted text)

      case kind.to_s
      when 'fin_meeting' then text.start_with?(FIN_RESULTS_BASE_URL) && text.length > FIN_RESULTS_BASE_URL.length
      when 'microplus' then site_url?(text, /\A[\w-]+\.microplustiming\.com\z/i) { |uri| uri.path.to_s.length > 1 }
      when 'ficr' then site_url?(text, /\Anuoto\.ficr\.it\z/i) { |uri| uri.fragment.to_s.length > 1 || uri.path.to_s.length > 1 }
      when 'goandswim' then site_url?(text, /\Arisultati\.goandswim\.it\z/i) { |uri| uri.path.to_s.match?(%r{\A/evento/\w+}) }
      else false
      end
    end

    # Result-page layout of a season for the calendar CSV crawls (layouts 2 and 3 are the same for result pages,
    # so the seasons from 182 on use layout 2; the older ones layout 1).
    def result_layout_for(season_id)
      season_id.to_i < 182 ? 1 : 2
    end

    # FIN calendar season text ('2025/2026') of a Season.
    def year_text_for(season)
      season ? "#{season.begin_date.year}/#{season.end_date.year}" : nil
    end

    def site_url?(text, host_regexp)
      uri = URI.parse(text)
      %w[http https].include?(uri.scheme&.downcase) && uri.host.to_s.match?(host_regexp) && yield(uri)
    rescue URI::InvalidURIError
      false
    end
    private_class_method :site_url?
  end
end
