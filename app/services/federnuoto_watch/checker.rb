# frozen_string_literal: true

module FedernuotoWatch
  #
  # = FedernuotoWatch::Checker
  #
  # Runs a single check of the watched page:
  #
  # 1. fetches & extracts a new snapshot;
  # 2. on the very first run, records it as baseline (no alert);
  # 3. when the digest changes, computes the diff between the last *acknowledged* snapshot and
  #    the new one (so that the pending alert always shows all the changes since it was last
  #    dismissed) and broadcasts the alert;
  # 4. when the page returns to the acknowledged state, clears the pending alert.
  #
  # 0.10.103: every new snapshot also updates the 'removed_rows' (StateStore.track_removed). The alert of a change is
  # raised only when the decision (+decide+, default FedernuotoWatch::Parity.decision) says :alert, which it always does
  # with the automation master switch off; a change with nothing to crawl (:nothing_to_crawl) or already followed up
  # (:parity) is acknowledged at once (FedernuotoWatch::Acknowledge, actor :auto: its notices are logged and shown in
  # "Needs you"), and one whose rows without a link wait for the 'Eventi' calendar crawl (:wait) stays pending without
  # an alert (the planner passes follow it up).
  #
  # Manual checks (from the UI) also broadcast a transient feedback message when nothing
  # changed or in case of errors. Errors are never re-raised: they are logged and stored as 'last_error'.
  #
  class Checker # rubocop:disable Metrics/ClassLength
    # Possible outcomes returned by #call
    OUTCOMES = %i[baseline unchanged changed reverted error].freeze

    def self.call(...)
      new(...).call
    end

    # - decide: callable(change) returning [decision Symbol, Parity::Result or nil] (see FedernuotoWatch::Parity.decision);
    # - acknowledger: callable(**args) acknowledging the change (default: FedernuotoWatch::Acknowledge.call on the same
    #   store and notifier).
    def initialize(manual: false, fetcher: Fetcher.new, store: StateStore.new, notifier: Notifier.new, decide: nil, acknowledger: nil) # rubocop:disable Metrics/ParameterLists
      @manual = manual
      @fetcher = fetcher
      @store = store
      @notifier = notifier
      @decide = decide || ->(change) { Parity.decision(change) }
      @acknowledger = acknowledger || ->(**args) { Acknowledge.call(store: @store, notifier: @notifier, **args) }
    end

    # Returns one of the OUTCOMES symbols.
    def call
      snapshot = Extractor.new(@fetcher.call).call
      outcome = nil
      state = @store.update do |current|
        outcome = apply_snapshot(current, snapshot)
        current
      end
      record_change_event(state) if outcome == :changed
      notify(outcome, state)
      outcome
    rescue StandardError => e
      handle_error(e)
    end

    # Computes the change between two lists of row Hashes (see Extractor).
    # Returns a Hash with the lists of 'added', 'removed', 'with_results' & 'updated' rows.
    def self.diff(old_rows, new_rows)
      old_by_key = index_rows(old_rows)
      new_by_key = index_rows(new_rows)
      with_results, others = (old_by_key.keys & new_by_key.keys).partition do |key|
        results_published?(old_by_key[key], new_by_key[key])
      end

      {
        'added' => new_by_key.except(*old_by_key.keys).values,
        'removed' => old_by_key.except(*new_by_key.keys).values,
        'with_results' => new_by_key.values_at(*with_results),
        'updated' => new_by_key.values_at(*others.reject { |key| same_status?(old_by_key[key], new_by_key[key]) })
      }
    end

    # When each row entered each list of the change (0.10.103): { list => { key => ISO time } }, a row keeping the time
    # of the previous (accumulating) change when it was already in that list, else +now+. Not part of the page digest.
    def self.row_detection_times(previous_change, change, now)
      known = previous_change.is_a?(Hash) && previous_change['row_detected_at'].is_a?(Hash) ? previous_change['row_detected_at'] : {}
      %w[added removed with_results updated].index_with do |list|
        Array(change[list]).grep(Hash).map { |row| row['key'] }.index_with { |key| known.dig(list, key) || now }
      end
    end

    # Returns the rows indexed by their 'key'.
    def self.index_rows(rows)
      Array(rows).index_by { |row| row['key'] }
    end

    # True when a results link has appeared on a row that didn't have one.
    def self.results_published?(old_row, new_row)
      old_row['url'].blank? && new_row['url'].present?
    end

    # True when the results link & the additional info of a row are unchanged.
    def self.same_status?(old_row, new_row)
      old_row.values_at('url', 'info') == new_row.values_at('url', 'info')
    end

    private

    def apply_snapshot(state, snapshot)
      now = Time.current.iso8601
      state['url'] = FedernuotoWatch::URL
      state['last_checked'] = now
      state['last_error'] = nil
      return record_baseline(state, snapshot) if state['digest'].blank?
      return :unchanged if state['digest'] == snapshot.digest

      store_snapshot(state, snapshot)
      if state['ack_digest'] == snapshot.digest
        state['change'] = nil
        return :reverted
      end

      state['change'] = accumulated_change(state, snapshot, now)
      :changed
    end

    # The change since the acknowledged snapshot, with its detection times (the first one and each row's are kept).
    def accumulated_change(state, snapshot, now)
      change = self.class.diff(state['ack_rows'], snapshot.rows)
      change.merge(
        'detected_at' => now, 'first_detected_at' => state.dig('change', 'first_detected_at') || now,
        'row_detected_at' => self.class.row_detection_times(state['change'], change, now)
      )
    end

    # The new snapshot, with the rows removed since the previous one (StateStore.track_removed).
    def store_snapshot(state, snapshot)
      state['removed_rows'] = StateStore.track_removed(state['removed_rows'], state['rows'], snapshot.rows)
      state['digest'] = snapshot.digest
      state['rows'] = snapshot.rows
    end

    # Appends 'fin.watch_changed' to the ops event log (never raises).
    def record_change_event(state)
      Ops.safely do
        change = state['change'] || {}
        counts = %w[added removed with_results updated].index_with { |key| Array(change[key]).size }
        Ops.record_event!(
          kind: 'fin.watch_changed', level: 'warning', actor: @manual ? 'operator' : 'job',
          subject_type: 'fin_watch', subject_key: state['digest'], data: counts.merge('url' => state['url'])
        )
      end
    end

    def record_baseline(state, snapshot)
      state['digest'] = state['ack_digest'] = snapshot.digest
      state['rows'] = state['ack_rows'] = snapshot.rows
      state['change'] = nil
      :baseline
    end

    def notify(outcome, state)
      case outcome
      when :changed
        notify_change(state)
      when :reverted
        @notifier.clear_change
      else # :baseline, :unchanged
        @notifier.broadcast_info(I18n.t('federnuoto_watch.check.no_changes', count: Array(state['rows']).size)) if @manual
      end
    end

    # The alert, or the acknowledge at once of a change with nothing to crawl (see the class notes).
    # (an automatic acknowledge that is refused, e.g. its trace could not be written, raises the alert after all)
    def notify_change(state)
      decision, parity = decided(state['change'])
      decision = :alert if %i[nothing_to_crawl parity].include?(decision) && !acknowledged_at_once?(state, decision, parity)
      case decision
      when :alert then @notifier.broadcast_change(state['change'], digest: state['digest'])
      when :wait then Progress.store!(parity.progress_payload(digest: state['digest'])) if parity # (keeps the alert hidden)
      end
      @notifier.broadcast_info(I18n.t("federnuoto_watch.check.#{decision}")) if @manual && decision != :alert
    end

    def acknowledged_at_once?(state, decision, parity)
      result = @acknowledger.call(actor: :auto, reason: decision.to_s, expected_digest: state['digest'], parity:)
      result.respond_to?(:acknowledged?) && result.acknowledged?
    end

    # [decision, parity] (an error, or an unknown decision, counts as :alert).
    def decided(change)
      decision, parity = @decide.call(change)
      %i[alert wait nothing_to_crawl parity].include?(decision) ? [decision, parity] : [:alert, nil]
    rescue StandardError => e
      Rails.logger.warn("[FedernuotoWatch::Checker] change decision failed, alert shown: #{e.class}: #{e.message}")
      [:alert, nil]
    end

    def handle_error(error)
      Rails.logger.error("[FedernuotoWatch::Checker] #{error.class}: #{error.message}")
      Rails.logger.debug { error.backtrace&.first(10)&.join("\n") }
      @store.update do |state|
        state['last_checked'] = Time.current.iso8601
        state['last_error'] = "#{error.class}: #{error.message}"
        state
      end
      @notifier.broadcast_error(I18n.t('federnuoto_watch.check.failed', error: error.message)) if @manual
      :error
    rescue StandardError => e
      Rails.logger.error("[FedernuotoWatch::Checker] error while handling error: #{e.class}: #{e.message}")
      :error
    end
  end
end
