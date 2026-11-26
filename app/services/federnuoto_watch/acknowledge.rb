# frozen_string_literal: true

module FedernuotoWatch
  #
  # = FedernuotoWatch::Acknowledge
  #
  # The one way a pending FIN change is acknowledged (0.10.103): the operator's dismiss of the sticky alert
  # (FedernuotoWatchController#acknowledge, actor :operator) and the automatic one (actor :auto: FedernuotoWatch::Checker
  # for a change with nothing to crawl, FedernuotoWatch::ParityCheck once FedernuotoWatch::Parity is reached).
  #
  # 1. StateStore#acknowledge!(expected_digest:): nothing happens when no change is pending any more (a second caller of
  #    the same digest: no duplicate event) or a newer snapshot landed since the caller looked (the hourly check racing
  #    a dismiss: its change is never acknowledged unseen);
  # 2. under the same file lock, BEFORE the state is written, the trace: an automatic acknowledge of a change holding
  #    notices (rows without a link, true removals, rows whose results were published while in review, a text-only
  #    change: FedernuotoWatch::Parity::Notices) records them as a 'fin.calendar_notice' event (once per change: an
  #    existing notice of the same digest and detection is reused), shown in "Needs you" until dismissed
  #    (Inbox::Sources::FINNotice), then the 'fin.watch_acknowledged' event (data: actor, reason, the change counts).
  #    The operator's dismiss records only the latter (the alert listed every row);
  # 3. the stored progress is dropped and the alert is removed from every open tab (Notifier#clear_change).
  #
  # Fail closed: an automatic acknowledge needs the ops DB and a trace written; when an event cannot be written nothing
  # is acknowledged (the change stays pending and its alert shows). The operator's dismiss works without the ops DB.
  # Never raises: a failure is logged and returns a Result with acknowledged false (the alert stays).
  #
  class Acknowledge
    ACTORS = %w[operator auto].freeze
    NOTICE_EVENT = 'fin.calendar_notice'
    ACK_EVENT = 'fin.watch_acknowledged'
    COUNTED = %w[added removed with_results updated].freeze

    # - acknowledged: true when the state was written; change: the change acknowledged (Hash or nil);
    # - notice_event: the 'fin.calendar_notice' Ops::Event recorded (or nil).
    Result = Data.define(:acknowledged, :change, :notice_event) do
      def acknowledged? = acknowledged
    end

    def self.call(...)
      new(...).call
    end

    # == Params
    # - actor: :operator or :auto; reason: a short code ('operator', 'parity', 'nothing_to_crawl');
    # - expected_digest: the snapshot digest the caller looked at (nil: whatever the latest is);
    # - parity: the FedernuotoWatch::Parity::Result the decision came from (its notices are recorded for :auto);
    # - store / notifier: StateStore / Notifier.
    def initialize(actor:, reason:, expected_digest: nil, parity: nil, store: StateStore.new, notifier: Notifier.new) # rubocop:disable Metrics/ParameterLists
      @actor = ACTORS.include?(actor.to_s) ? actor.to_s : 'operator'
      @reason = reason.to_s.presence || @actor
      @expected_digest = expected_digest
      @parity = parity
      @store = store
      @notifier = notifier
    end

    def call
      return refused if auto? && !Ops.available?

      change = nil
      notice = nil
      saved = @store.acknowledge!(expected_digest: @expected_digest) do |state|
        change = state['change']
        notice = record_trace(state, change)
        !notice.nil? || !auto?
      end
      return refused(change) unless saved

      Progress.clear!
      clear_alert
      Result.new(acknowledged: true, change:, notice_event: notice.is_a?(Ops::Event) ? notice : nil)
    rescue StandardError => e
      Rails.logger.error("[FedernuotoWatch::Acknowledge] #{@actor}: #{e.class}: #{e.message}")
      refused
    end

    private

    def auto? = @actor == 'auto'

    def refused(change = nil) = Result.new(acknowledged: false, change:, notice_event: nil)

    # Writes the trace of the acknowledge (under the store lock, before the state). Returns the notice Ops::Event, :none
    # (no notice needed) or nil when an event could not be written (an automatic acknowledge is then refused).
    def record_trace(state, change)
      notice = auto? ? record_notice(state, change) : :none
      return nil if notice.nil?

      record_acknowledged(state, change) ? notice : nil
    end

    def clear_alert
      @notifier.clear_change
    rescue StandardError => e
      Rails.logger.warn("[FedernuotoWatch::Acknowledge] alert clear not broadcast: #{e.class}: #{e.message}")
    end

    def counts(change)
      COUNTED.index_with { |key| Array(change&.dig(key)).size }
    end

    def record_acknowledged(state, change)
      data = counts(change).merge('actor' => @actor, 'reason' => @reason)
      data['actionable'] = @parity.actionable.size if @parity
      Ops.record_event!(kind: ACK_EVENT, level: 'info', actor: auto? ? 'job' : 'operator', subject_type: 'fin_watch',
                        subject_key: state['digest'], data:, link_path: season_board_path)
    end

    # The 'fin.calendar_notice' event of the notices of the change (the existing one of the same digest and detection,
    # if any), :none when it holds no notice, nil when it could not be written.
    def record_notice(state, change)
      notices = @parity&.notices || fallback_notices(change, state)
      return :none unless notices.any?

      existing_notice(state['digest'], change['detected_at']) ||
        Ops.record_event!(kind: NOTICE_EVENT, level: 'info', actor: 'job', subject_type: 'fin_watch', subject_key: state['digest'],
                          data: notices.to_h.merge('reason' => @reason, 'detected_at' => change['detected_at']), link_path: season_board_path)
    end

    def existing_notice(digest, detected_at)
      Ops.safely do
        Ops::Event.of_kind(NOTICE_EVENT).for_subject('fin_watch', digest).recent.limit(5).find { |event| event.data.to_h['detected_at'] == detected_at }
      end
    end

    # Notices without a parity result: every row without its own FIN link, and the removals that are no rename.
    def fallback_notices(change, state)
      rows = Array(state['rows']).grep(Hash)
      without_link = Parity::CHANGE_KEYS.flat_map do |section|
        Array(change[section]).grep(Hash).reject { |row| FINEventId.parse(row['url']) }
                              .map { |row| Parity::Item.new(section:, row:, board_row: nil, fin_event_id: nil, reason: nil) }
      end
      removed = Array(change['removed']).grep(Hash).reject { |row| StateStore.renamed?(row, rows) }
      text_only = COUNTED.all? { |key| Array(change[key]).empty? }
      Parity::Notices.new(without_link:, removed:, text_only:)
    end

    def season_board_path
      Rails.application.routes.url_helpers.season_board_path
    end
  end
end
