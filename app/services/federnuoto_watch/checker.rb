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
  # Manual checks (from the UI) also broadcast a transient feedback message when nothing
  # changed or in case of errors. Errors are never re-raised: they are logged and stored as 'last_error'.
  #
  class Checker
    # Possible outcomes returned by #call
    OUTCOMES = %i[baseline unchanged changed reverted error].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(manual: false, fetcher: Fetcher.new, store: StateStore.new, notifier: Notifier.new)
      @manual = manual
      @fetcher = fetcher
      @store = store
      @notifier = notifier
    end

    # Returns one of the OUTCOMES symbols.
    def call
      snapshot = Extractor.new(@fetcher.call).call
      outcome = nil
      state = @store.update do |current|
        outcome = apply_snapshot(current, snapshot)
        current
      end
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

      state['digest'] = snapshot.digest
      state['rows'] = snapshot.rows
      if state['ack_digest'] == snapshot.digest
        state['change'] = nil
        return :reverted
      end

      state['change'] = self.class.diff(state['ack_rows'], snapshot.rows).merge(
        'detected_at' => now,
        'first_detected_at' => state.dig('change', 'first_detected_at') || now
      )
      :changed
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
        @notifier.broadcast_change(state['change'])
      when :reverted
        @notifier.clear_change
      else # :baseline, :unchanged
        @notifier.broadcast_info(I18n.t('federnuoto_watch.check.no_changes', count: Array(state['rows']).size)) if @manual
      end
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
