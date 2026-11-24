# frozen_string_literal: true

module Health
  #
  # = Health::FindingLinks
  #
  # What a finding offers, from its stored payload alone (Ops::HealthFinding#payload):
  # - #actions: the links (Data-Fix review, Outbox, Season board row, FIN results page); the Fix buttons of the
  #   maintenance operations (phase 11, "Flag cancelled" included) come from Maintenance::FixButtonComponent;
  # - #entity_links: links to the entity grids (Meetings, Calendars, Badges, Teams) filtered on the subject. Those
  #   grid pages query the API: they show the remote rows, not the local mirror.
  # The copyable rake command and the how-to text come from the Health::Registry check (see FindingDetailComponent).
  #
  class FindingLinks
    # kind: Symbol; label: translated text; path: app path or external URL; http_method: :get; external: true for a
    # page outside the app (opened in a new tab).
    Link = Data.define(:kind, :label, :path, :external) do
      def external? = external
    end

    attr_reader :finding

    # The Outbox page focused on a pending SQL script (by file name).
    def self.push_path(sql_path)
      SeasonBoard::ActionPaths.outbox_focus_path(sql_path)
    end

    # == Params:
    # - finding: Ops::HealthFinding;
    # - board_season_id: the Season board season ID (the board row link is offered only for it).
    def initialize(finding, board_season_id: nil)
      @finding = finding
      @board_season_id = board_season_id
    end

    # Action links, in display order (ignore / acknowledge are the bulk buttons, not links).
    def actions
      [review_link, push_link, board_link, results_page_link].compact
    end

    # Links to the entity grids for the subject.
    def entity_links
      case finding.subject_type
      when 'meeting' then [meeting_link(payload['meeting_id'] || finding.subject_id, payload['description'])].compact
      when 'calendar', 'calendars' then [link(:calendars, 'calendars', url_helpers.api_calendars_path(calendars_grid: { season_id: }))]
      else swimmer_or_team_links
      end
    end

    private

    def payload = finding.payload.is_a?(Hash) ? finding.payload : {}
    def season_id = finding.season_id
    def url_helpers = Rails.application.routes.url_helpers

    def link(kind, label_key, path, external: false, **interpolations)
      Link.new(kind:, label: I18n.t("health.links.#{label_key}", **interpolations), path:, external:)
    end

    def review_link
      disk = payload['disk']
      return unless disk.is_a?(Hash) && disk['review_path'].present?

      path = if disk['phase'].present?
               SeasonBoard::ActionPaths.link_path(SeasonBoard::NextAction.new(kind: :resume_review,
                                                                              params: { file_path: disk['review_path'], phase: disk['phase'] }))
             else
               url_helpers.review_sessions_path(file_path: disk['review_path'], phase_v2: 1)
             end
      link(:review, disk['phase'].present? ? 'resume_review' : 'review', path, phase: disk['phase'])
    end

    def push_link
      sql_path = payload.dig('disk', 'sql_path')
      return if sql_path.blank?

      link(:push, 'push', self.class.push_path(sql_path))
    end

    def board_link
      fin_event_id = payload['fin_event_id']
      return if fin_event_id.blank? || @board_season_id.nil? || season_id != @board_season_id

      link(:board, 'season_board', SeasonBoard::ActionPaths.board_row_path(fin_event_id))
    end

    def results_page_link
      url = payload['results_link'].to_s
      return unless url.start_with?('http://', 'https://')

      link(:results_page, 'results_page', url, external: true)
    end

    def meeting_link(meeting_id, description)
      return unless meeting_id

      grid = { season_id:, description: description.to_s.truncate(60, omission: '') }.compact_blank
      link(:meeting, 'meeting', url_helpers.api_meetings_path(meetings_grid: grid), id: meeting_id)
    end

    def swimmer_or_team_links
      case finding.subject_type
      when 'swimmer', 'badge' then [badges_link(payload['swimmer_id'] || finding.subject_id)].compact
      when 'swimmers' then finding.subject_id_list.filter_map { |id| badges_link(id) }
      when 'teams' then team_links
      else []
      end
    end

    def badges_link(swimmer_id)
      return unless swimmer_id

      link(:badges, 'badges', url_helpers.api_badges_path(badges_grid: { season_id:, swimmer_id: }), id: swimmer_id)
    end

    def team_links
      Array(payload['teams']).map do |team|
        link(:team, 'team', url_helpers.api_badges_path(badges_grid: { season_id:, team_id: team['id'] }), id: team['id'])
      end
    end
  end
end
