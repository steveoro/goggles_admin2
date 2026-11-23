# frozen_string_literal: true

module Drift
  #
  # = Drift::Verdict
  #
  # Pure function turning the two fingerprints (Drift::Fingerprint) and the local facts (Outbox scripts, remote
  # writes) into a DB sync verdict and its reasons. Counts and max ids are compared, never timestamps for equality
  # (the pushed scripts write NOW()); the remote max updated_at is only compared with the time of the last script
  # known to be applied on the server.
  #
  # == Verdicts (the worst one wins: red > unknown > amber > green)
  # - green: every table has the same count and max id; or the local DB is ahead (local max id >= remote) while
  #   scripts are still to be applied on the server ('local_ahead', with the number of those scripts);
  # - amber: same max id but different count ('count_differs'); successful remote-only writes since the last green
  #   check / acknowledgement ('remote_writes'); remote max updated_at of an import-owned table later than the last
  #   applied script ('remote_updated'); local ahead with nothing left to push ('local_ahead_unpushed'); remote max
  #   id above the local one on a table the commits never insert into ('remote_ahead'); a script deleted on the server
  #   ('missing_remote'); tables that could not be compared ('table_unknown');
  # - red: remote max id above the local one on a table the commits insert into ('id_collision', e.g. laps added by
  #   users); a failed script ('failed_script', or 'failed_partial' when it was not a single transaction: it may be
  #   partially applied); failed batch rows on the server ('remote_batch_failed'); different schema versions
  #   ('schema_mismatch');
  # - unknown: no comparison possible (API unreachable, no or expired JWT, no 'db_fingerprint' capability, ...):
  #   reason code = the remote status.
  #
  # Each reason is a Hash { 'code', 'table', 'local', 'remote' } (texts 'db_sync.reasons.<code>'), red ones first.
  #
  # == Usage
  #   result = Drift::Verdict.call(local:, remote:, outbox: Drift::Verdict::OutboxFacts.current(base_url), remote_writes: 0)
  #   result.verdict  # => 'green' | 'amber' | 'red' | 'unknown'
  #   result.reasons  # => [{ 'code' => 'local_ahead', 'table' => 'laps', 'local' => 120, 'remote' => 100 }, ...]
  #
  class Verdict # rubocop:disable Metrics/ClassLength
    RED_CODES = %w[id_collision failed_script failed_partial remote_batch_failed schema_mismatch].freeze
    AMBER_CODES = %w[
      count_differs remote_writes remote_updated local_ahead_unpushed remote_ahead missing_remote table_unknown stale
    ].freeze
    GREEN_CODES = %w[in_sync local_ahead].freeze
    # (clock skew between the servers: a remote updated_at within this margin of the last applied script is fine)
    UPDATED_AT_MARGIN = 2.minutes

    Result = Data.define(:verdict, :reasons) do
      def codes = reasons.map { |reason| reason['code'] }
    end

    # Local Outbox facts used by the verdict (see .current).
    # - pending: scripts not on the server yet (pending, held, pushing, in doubt); sent: queued on the server;
    # - failed: [[filename, single_transaction, remote_iq_id], ...]; missing_remote: count;
    # - last_applied_at: time of the last script seen applied (or executed) on that server, or nil.
    OutboxFacts = Data.define(:pending, :sent, :failed, :missing_remote, :last_applied_at) do
      def self.empty = new(pending: 0, sent: 0, failed: [], missing_remote: 0, last_applied_at: nil)

      # Facts for the scripts pushed (or to push) to +base_url+ (the empty facts without the ops DB).
      def self.current(base_url)
        Ops.safely(empty) do
          next empty unless Ops.available?

          url = base_url.to_s.strip.delete_suffix('/')
          on_url = Ops::SqlScript.where(target_api_url: [url, "#{url}/"])
          new(pending: Ops::SqlScript.in_state(Ops::SqlScript::NEEDS_PUSH_STATES).count, sent: on_url.sent.count,
              failed: on_url.failed.ordered.pluck(:filename, :single_transaction, :remote_iq_id),
              missing_remote: on_url.missing_remote.count,
              last_applied_at: on_url.in_state('applied', 'executed_unreported').maximum(:resolved_at))
        end
      end

      def unapplied = pending + sent
    end

    def self.call(**options)
      new(**options).call
    end

    # == Params:
    # - local: the local fingerprint Hash; remote: a Drift::Fingerprint::Remote;
    # - outbox: OutboxFacts; remote_writes: successful remote-only writes since the last green check/acknowledgement;
    # - acknowledged_at: time of the last acknowledgement on /remote_writes or /db_sync (or nil).
    def initialize(local:, remote:, outbox: OutboxFacts.empty, remote_writes: 0, acknowledged_at: nil)
      @local = local.is_a?(Hash) ? local : {}
      @remote = remote
      @outbox = outbox
      @remote_writes = remote_writes.to_i
      @acknowledged_at = acknowledged_at
      @reasons = []
    end

    def call
      outbox_reasons
      if remote&.ok?
        schema_reasons
        table_reasons
        batch_reasons
        @reasons << reason('remote_writes', local: @remote_writes) if @remote_writes.positive?
      end
      Result.new(verdict: verdict_for, reasons: sorted_reasons)
    end

    private

    attr_reader :local, :remote, :outbox

    def reason(code, table: nil, local: nil, remote: nil)
      { 'code' => code, 'table' => table, 'local' => local, 'remote' => remote }
    end

    def verdict_for
      codes = @reasons.pluck('code')
      return 'red' if codes.intersect?(RED_CODES)
      return 'unknown' unless remote&.ok?
      return 'amber' if codes.intersect?(AMBER_CODES)

      'green'
    end

    # Red first, then amber, unknown, green (stable inside each group); 'in_sync' only when nothing else.
    def sorted_reasons
      list = @reasons.dup
      list << reason(remote ? remote.status : 'error', remote: remote&.error) unless remote&.ok?
      list << reason('in_sync') if list.empty?
      list.each_with_index.sort_by { |item, index| [rank_of(item['code']), index] }.map(&:first)
    end

    def rank_of(code)
      return 0 if RED_CODES.include?(code)
      return 1 if AMBER_CODES.include?(code)
      return 3 if GREEN_CODES.include?(code)

      2
    end

    def outbox_reasons
      outbox.failed.each do |filename, single_transaction, remote_iq_id|
        @reasons << reason(single_transaction == false ? 'failed_partial' : 'failed_script', local: filename, remote: remote_iq_id)
      end
      @reasons << reason('missing_remote', local: outbox.missing_remote) if outbox.missing_remote.positive?
    end

    def schema_reasons
      local_version = local['schema_version'].to_s
      remote_version = remote.payload['schema_version'].to_s
      return if local_version.blank? || remote_version.blank? || local_version == remote_version

      @reasons << reason('schema_mismatch', local: local_version, remote: remote_version)
    end

    def batch_reasons
      failed = remote.payload.dig('import_queue', 'batch_failed').to_i
      # (our own failed scripts are already reported one by one)
      @reasons << reason('remote_batch_failed', remote: failed) if failed.positive? && outbox.failed.empty?
    end

    def table_reasons
      local_tables = local['tables'].is_a?(Hash) ? local['tables'] : {}
      ahead = []
      (Drift::Tables.all & (local_tables.keys | remote.tables.keys)).each do |table|
        compare_table(table, local_tables[table], remote.tables[table], ahead)
      end
      ahead_reasons(ahead)
    end

    def compare_table(table, mine, theirs, ahead)
      return @reasons << reason('table_unknown', table:) unless mine.is_a?(Hash) && theirs.is_a?(Hash)

      local_max = mine['max_id'].to_i
      remote_max = theirs['max_id'].to_i
      if remote_max > local_max
        code = Drift::Tables.commit_table?(table) ? 'id_collision' : 'remote_ahead'
        @reasons << reason(code, table:, local: local_max, remote: remote_max)
      elsif local_max > remote_max
        ahead << reason('local_ahead', table:, local: local_max, remote: remote_max)
      elsif count_differs?(mine, theirs)
        @reasons << reason('count_differs', table:, local: mine['count'], remote: theirs['count'])
      end
      updated_at_reason(table, theirs)
    end

    def count_differs?(mine, theirs)
      mine.key?('count') && theirs.key?('count') && mine['count'].to_i != theirs['count'].to_i
    end

    # Local ahead: green while scripts are still to apply on the server, amber otherwise.
    def ahead_reasons(ahead)
      return if ahead.empty?

      code = outbox.unapplied.positive? ? 'local_ahead' : 'local_ahead_unpushed'
      ahead.each { |item| @reasons << item.merge('code' => code) }
    end

    # Import-owned tables only (users change the others all the time); full mode only.
    def updated_at_reason(table, theirs)
      return unless Drift::Tables.import_owned?(table) && theirs['max_updated_at'].present?

      reference = [outbox.last_applied_at, @acknowledged_at].compact.max
      return unless reference

      remote_time = Time.zone.parse(theirs['max_updated_at'].to_s)
      return unless remote_time && remote_time > reference + UPDATED_AT_MARGIN

      @reasons << reason('remote_updated', table:, local: reference.utc.iso8601, remote: remote_time.utc.iso8601)
    rescue ArgumentError
      nil
    end
  end
end
