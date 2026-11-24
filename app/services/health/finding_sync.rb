# frozen_string_literal: true

module Health
  #
  # = Health::FindingSync
  #
  # Persists the findings of a SUCCESSFUL group run (Ops::HealthRun) into Ops::HealthFinding, keeping the
  # operator's triage. Rules (season + group of the run):
  # 1. every finding seen is upserted by (season_id, check_key, fingerprint): a new row starts 'open'; a row seen
  #    again refreshes last_seen_*, severity, payload, payload_digest and title, and keeps its status;
  # 2. unseen 'open' / 'acknowledged' rows become 'resolved' (resolved_at set); unseen 'ignored' rows stay ignored;
  # 3. a 'resolved' row seen again goes back to 'open' (its note is kept);
  # 4. an 'acknowledged' row whose payload digest changed goes back to 'open'; an 'ignored' row stays ignored
  #    whatever changes.
  # A failed or skipped run is never synced (Health::Runner calls this only after a successful run).
  #
  # Resolved rows older than Ops::HealthFinding::RESOLVED_RETENTION are pruned at the end.
  #
  class FindingSync
    # - counts: Hash check key => { 'open' => findings open after the sync, 'seen' =>, 'new' => created or reopened,
    #   'resolved' => resolved by this run } for every check of the group;
    # - findings_count (seen), new_count, resolved_count: totals.
    Result = Data.define(:counts, :findings_count, :new_count, :resolved_count)

    attr_reader :run

    # == Params:
    # - run: the succeeded Ops::HealthRun (season_id, group_key, id);
    # - findings: Array of Health::Finding emitted by the group run.
    def initialize(run:, findings:, now: Time.current)
      @run = run
      @findings = findings.index_by { |finding| fingerprint(finding) }.values
      @now = now
    end

    # Applies the rules (one ops DB transaction). Returns a Result.
    def call
      counts = Health::Registry.for_group(run.group_key).map(&:key).index_with { empty_count }
      Ops::HealthFinding.transaction do
        existing = group_rows.index_by { |row| [row.check_key, row.fingerprint] }
        seen = @findings.map { |finding| save_seen(finding, existing, counts) }
        resolve_unseen(existing.values - seen, counts)
      end
      count_open(counts)
      Ops::HealthFinding.prune_resolved!(now: @now)
      result_for(counts)
    end

    private

    UNRESOLVED = %w[open acknowledged].freeze
    private_constant :UNRESOLVED

    def empty_count = { 'open' => 0, 'seen' => 0, 'new' => 0, 'resolved' => 0 }

    def group_rows = Ops::HealthFinding.for_season(run.season_id).for_group(run.group_key)

    def result_for(counts)
      Result.new(counts:, findings_count: @findings.size, new_count: counts.values.sum { |count| count['new'] },
                 resolved_count: counts.values.sum { |count| count['resolved'] })
    end

    def fingerprint(finding)
      Ops::HealthFinding.fingerprint_for(check_key: finding.check_key, season_id: run.season_id, identity: finding.identity)
    end

    # Creates or refreshes the row of a finding seen by the run; returns it.
    def save_seen(finding, existing, counts)
      count = (counts[finding.check_key] ||= empty_count)
      count['seen'] += 1
      payload = finding.stored_payload
      digest = Ops::HealthFinding.digest_for(payload)
      row = existing[[finding.check_key, fingerprint(finding)]]
      if row.nil?
        count['new'] += 1
        return create_row(finding, payload, digest)
      end

      status = next_status(row, digest)
      count['new'] += 1 if status == 'open' && row.status != 'open'
      row.update!(seen_attributes(finding, payload, digest).merge(status_change(row, status)))
      row
    end

    def create_row(finding, payload, digest)
      Ops::HealthFinding.create!(
        season_id: run.season_id, group_key: run.group_key, check_key: finding.check_key, fingerprint: fingerprint(finding),
        status: 'open', first_seen_run_id: run.id, first_seen_at: @now, **seen_attributes(finding, payload, digest)
      )
    end

    def seen_attributes(finding, payload, digest)
      { severity: finding.severity, subject_type: finding.subject_type, subject_id: finding.subject_id,
        subject_ids: finding.subject_ids.join(',').presence, title: finding.title.to_s.truncate(255), payload:,
        payload_digest: digest, last_seen_run_id: run.id, last_seen_at: @now }
    end

    # Rules 1, 3 and 4.
    def next_status(row, digest)
      case row.status
      when 'resolved' then 'open'
      when 'acknowledged' then row.payload_digest == digest ? 'acknowledged' : 'open'
      else row.status
      end
    end

    def status_change(row, status)
      return {} if status == row.status

      { status:, resolved_at: nil, status_changed_at: @now, status_changed_by: nil }
    end

    # Rule 2.
    def resolve_unseen(rows, counts)
      rows.each do |row|
        next unless UNRESOLVED.include?(row.status)

        row.update!(status: 'resolved', resolved_at: @now, status_changed_at: @now, status_changed_by: nil)
        (counts[row.check_key] ||= empty_count)['resolved'] += 1
      end
    end

    def count_open(counts)
      group_rows.open_status.group(:check_key).count.each do |key, open|
        (counts[key] ||= empty_count)['open'] = open
      end
    end
  end
end
