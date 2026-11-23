# frozen_string_literal: true

module Outbox
  #
  # = Outbox::ScriptRowComponent
  #
  # One Ops::SqlScript as a row of the Outbox tables: sequence, file (details link + SQL preview), kind, folder,
  # size, state, origin link and the quick actions of the row.
  #
  # == Params:
  # - script: the Ops::SqlScript;
  # - blocker: the lower-seq blocking script, if any (pending rows only: "after NNNN");
  # - focus: true to highlight the row (the page scrolls to it);
  # - selectable: true to show the selection checkbox (pending rows of 'Needs push');
  # - preview: [text, truncated] (see OutboxController#preview_for), or nil for no preview;
  # - remote: true for the 'On the server' columns (queue id, pushed at) instead of the origin.
  #
  class ScriptRowComponent < ViewComponent::Base
    def initialize(script:, blocker: nil, focus: false, selectable: false, preview: nil, remote: false) # rubocop:disable Metrics/ParameterLists
      super()
      @script = script
      @blocker = blocker
      @focus = focus
      @selectable = selectable
      @preview = preview
      @remote = remote
    end

    protected

    attr_reader :script, :blocker, :preview

    def focus? = @focus
    def selectable? = @selectable && script.pending?
    def remote? = @remote

    def dom_id = "outbox-script-#{script.id}"

    def row_css
      [('table-warning outbox-focus' if focus?), ('table-danger' if script.in_doubt?)].compact.join(' ')
    end

    def size_text
      helpers.number_to_human_size(script.byte_size.to_i)
    end

    def preview_text = preview&.first
    def preview_truncated? = preview&.last

    # [label, path] pairs for the origin column (path nil for plain text).
    def origin_links # rubocop:disable Metrics/AbcSize
      origin = script.origin_data
      links = []
      if origin['fin_event_id'].present?
        links << [t('outbox.origin.fin_event', id: origin['fin_event_id']),
                  SeasonBoard::ActionPaths.board_row_path(origin['fin_event_id'])]
      end
      links << [t('outbox.origin.meeting', id: origin['meeting_id']), nil] if origin['meeting_id'].present?
      links << [t('outbox.origin.calendar', id: origin['calendar_id']), nil] if origin['calendar_id'].present?
      links << [t('outbox.origin.task', task: origin['task']), nil] if origin['task'].present?
      links << [origin['producer'], nil] if links.empty? && origin['producer'].present?
      links
    end

    def pushed_at_text
      script.pushed_at ? l(script.pushed_at.localtime, format: :short) : '-'
    end
  end
end
