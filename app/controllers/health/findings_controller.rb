# frozen_string_literal: true

module Health
  #
  # = Health::FindingsController
  #
  # - show: one data health finding (evidence, entity links, rake command, how-to, actions, triage);
  # - bulk: acknowledge / ignore (note required) / reopen a selection of findings. Each change stores the note, the
  #   status change time and user, and appends one 'health.findings_triaged' Ops::Event. Resolved findings are
  #   left untouched (the next run reopens them when seen again).
  #
  class FindingsController < BaseController
    OPERATIONS = { 'acknowledge' => 'acknowledged', 'ignore' => 'ignored', 'reopen' => 'open' }.freeze
    # Statuses each operation applies to.
    FROM_STATUSES = { 'acknowledge' => %w[open], 'ignore' => %w[open acknowledged], 'reopen' => %w[acknowledged ignored] }.freeze
    NOTE_LIMIT = 500

    # GET /health/findings/:id
    def show
      return render(:unavailable, status: :service_unavailable) unless ops_available?

      @finding = Ops::HealthFinding.find_by(id: params[:id])
      return head(:not_found) unless @finding

      @season = GogglesDb::Season.unscoped.find_by(id: @finding.season_id)
      @board_season_id = SeasonBoard::Builder.latest_season&.id
      @run = Ops::HealthRun.find_by(id: @finding.last_seen_run_id)
      @stale = @run.present? && @run.db_epoch.to_i < Ops::Setting.db_epoch
      @null_swimmers_first = @finding.payload.is_a?(Hash) && @finding.payload['null_swimmers_first']
    end

    # PATCH /health/findings/bulk (ids[], operation, note, return_to)
    def bulk
      operation = params[:operation].to_s
      ids = selected_ids
      note = params[:note].to_s.strip.truncate(NOTE_LIMIT)
      error = bulk_error(operation, ids, note)
      if error
        flash[:alert] = error
      else
        flash[:notice] = apply_bulk(operation, ids, note)
      end
      redirect_to(safe_return_path(health_path))
    end

    private

    def selected_ids
      Array(params[:ids]).map(&:to_i).uniq.select(&:positive?)
    end

    def bulk_error(operation, ids, note)
      return t('health.bulk.errors.ops_unavailable') unless ops_available?
      return t('health.bulk.errors.unknown_operation') unless OPERATIONS.key?(operation)
      return t('health.bulk.errors.no_selection') if ids.empty?

      t('health.bulk.errors.note_required') if operation == 'ignore' && note.blank?
    end

    # Returns the flash text.
    def apply_bulk(operation, ids, note)
      rows = Ops::HealthFinding.where(id: ids, status: FROM_STATUSES.fetch(operation)).to_a
      now = Time.current
      Ops::HealthFinding.transaction do
        rows.each do |row|
          attributes = { status: OPERATIONS.fetch(operation), status_changed_at: now, status_changed_by: current_user&.id }
          attributes[:note] = note if note.present?
          row.update!(attributes)
        end
      end
      record_triage_event(operation, rows, note)
      Health::Notifier.ping
      t("health.bulk.done.#{operation}", count: rows.size, skipped: ids.size - rows.size)
    end

    def record_triage_event(operation, rows, note)
      return if rows.empty?

      Ops.record_event!(
        kind: 'health.findings_triaged', level: 'info', actor: 'operator', season_id: rows.map(&:season_id).uniq.one? ? rows.first.season_id : nil,
        subject_type: 'health_check', subject_key: rows.map(&:check_key).uniq.join(','),
        data: { 'operation' => operation, 'count' => rows.size, 'finding_ids' => rows.map(&:id).first(50), 'note' => note.presence }.compact,
        link_path: rows.one? ? health_finding_path(rows.first) : health_season_path(rows.first.season_id)
      )
    end
  end
end
