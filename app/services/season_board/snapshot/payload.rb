# frozen_string_literal: true

module SeasonBoard
  class Snapshot
    #
    # = SeasonBoard::Snapshot::Payload
    #
    # Turns a Builder::Result into the plain, JSON-able Hash stored in Ops::Snapshot (String keys;
    # values are only Hash, Array, String, Integer, true/false and nil: dates and times as ISO 8601
    # Strings, Symbols as Strings). No AR object, DiskIndex::Entry or ActivityLog::Entry is kept.
    # See SeasonBoard::Snapshot for the layout.
    #
    module Payload
      module_function

      # Returns the payload Hash.
      # - season_id: board season id; fingerprint: Fingerprint digest (or nil);
      # - today: reference date for the "past & done" count; built_at: time of the build.
      def call(result, season_id:, fingerprint:, today: Date.current, built_at: Time.current)
        {
          'version' => FORMAT_VERSION, 'season_id' => season_id&.to_i, 'fingerprint' => fingerprint,
          'built_at' => built_at.iso8601, 'snapshot_checked_at' => result.snapshot_checked_at&.iso8601,
          'state_counts' => result.state_counts.transform_keys(&:to_s), 'unlinked_count' => result.unlinked_count,
          'done_count' => result.done_count(today:),
          'rows' => result.rows.map { |row| row_payload(row) },
          'unmatched_sources' => Array(result.unmatched_sources).map { |entry| unmatched_payload(entry, pipeline_for(result, entry)) },
          'board_sql_paths' => Array(result.pending_board_sql_paths).map(&:to_s),
          'warnings' => Array(result.warnings).map(&:to_s), 'off_board_sources' => off_board_payload(result)
        }
      end

      # Pending disk entries whose FIN id is on no board row (Builder::Result#off_board_sources, 0.10.102), as the
      # unmatched ones plus their 'fin_event_id'.
      def off_board_payload(result)
        entries = result.respond_to?(:off_board_sources) ? Array(result.off_board_sources) : []
        entries.map { |entry| unmatched_payload(entry).merge('fin_event_id' => entry.fin_event_id) }
      end

      # Row members copied as plain values (see Snapshot::Row).
      ROW_ATTRIBUTES = %i[fin_event_id key name date_text year first_date last_date place url info meeting_id calendar_id].freeze

      # Plain Hash for a Builder Row.
      def row_payload(row)
        ROW_ATTRIBUTES.to_h { |attr| [attr.to_s, plain(row.public_send(attr))] }.merge(
          'state' => row.state.to_s, 'state_detail' => plain(row.state_detail || {}),
          'next_action' => action_payload(row.next_action), 'busy' => row.busy? || false, 'flags' => Array(row.flags).map(&:to_s),
          'locked' => (row.respond_to?(:locked?) && row.locked?) || false,
          'adopted_link' => adopted_link_payload(row.respond_to?(:adopted_link) ? row.adopted_link : nil)
        )
      end

      # Plain Hash of the CalendarIndex::Link lent by the 'Eventi' calendar (0.10.102), or nil.
      def adopted_link_payload(link)
        link && plain(link.to_h)
      end

      # Plain Hash for a NextAction (or nil).
      def action_payload(action)
        action && { 'kind' => action.kind.to_s, 'params' => plain(action.params) }
      end

      # Plain Hash for a DiskIndex::Entry without FIN id (pending files not matched to any FIN row).
      # 'pending': in_review (phase files), source (a source to review), sql (commit SQL to push)
      # or manifest (a manifest PDF to extract); 'review_path': file for the Data-Fix review (or nil);
      # 'pipeline' (phase 15, nil without one): { 'state', 'detail' } of the source prepared from the Sources page.
      def unmatched_payload(entry, facts = nil)
        source = entry.review_source || entry.sources.max_by { |src| src.mtime.to_f }
        {
          'base' => entry.bases.first, 'bases' => entry.bases.dup, 'pending' => unmatched_kind(entry),
          'review_path' => source&.review_path, 'phase' => entry.phase,
          'paths' => unmatched_paths(entry), 'pipeline' => pipeline_payload(facts)
        }
      end

      # The pipeline facts of an unmatched entry (Builder::Result#unmatched_pipeline, by base), or nil.
      def pipeline_for(result, entry)
        pipeline = result.respond_to?(:unmatched_pipeline) ? result.unmatched_pipeline : nil
        pipeline.is_a?(Hash) ? pipeline[entry.bases.first] : nil
      end

      # { 'state' => String, 'detail' => Hash } of PipelineIndex::Facts with a pipeline state, else nil.
      def pipeline_payload(facts)
        state, detail = facts&.state_and_detail
        state && { 'state' => state.to_s, 'detail' => plain(detail) }
      end

      def unmatched_kind(entry)
        if entry.review_source then 'in_review'
        elsif entry.sources.any? then 'source'
        elsif entry.sql_pending? then 'sql'
        elsif entry.manifest_pending? then 'manifest'
        end
      end

      def unmatched_paths(entry)
        source_paths = entry.sources.flat_map { |src| [src.lt2_path, src.lt4_path, *src.phase_paths.values] }
        [*source_paths, *entry.sql_new_paths, *entry.manifest_pdf_paths].compact.map(&:to_s).uniq
      end

      # Deep copy of +value+ made only of JSON-native values (String keys).
      def plain(value)
        case value
        when Hash then value.to_h { |key, val| [key.to_s, plain(val)] }
        when Array then value.map { |val| plain(val) }
        when String, Integer, Float, true, false, nil then value
        when Date, Time, ActiveSupport::TimeWithZone, DateTime then value.iso8601
        else value.to_s
        end
      end
    end
  end
end
