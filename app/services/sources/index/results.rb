# frozen_string_literal: true

module Sources
  class Index
    #
    # = Sources::Index::Results
    #
    # Rows of the Results tab: one per source pending in 'results.new/<season>' (the LT2 file, else the LT4 one, else
    # the highest phase file), newest first, with its FIN id (or "non-FIN"), layout, phase files, staged rows and
    # pipeline state. The one primary action:
    # - a FIN source: the Data-Fix entry (open, or resume at its step), the board row being one badge away;
    # - a non-FIN source (Microplus, FICR, Go&Swim, PDF-derived): "Prepare" (phase 10 DataFixPrepareJob through
    #   SeasonBoard::Scheduler.prepare!), then the step to review or the commit summary once prepared.
    #
    class Results
      # Labels of the states waiting for a prepare job (no verdict-based state to show).
      WAITING_LABELS = { preparing: 'pipeline_automation.stages.preparing', prepare_queued: 'season_board.activity.prepare_queued' }.freeze

      def initialize(index)
        @index = index
      end

      def rows
        disk = SeasonBoard::DiskIndex.new(season_id: @index.season_id, data_dir: @index.data_root)
        entries = disk.entries.values + disk.unmatched
        entries.flat_map { |entry| entry_rows(entry) }.sort_by { |row| [-row.mtime.to_f, row.name] }
      end

      private

      def entry_rows(entry)
        facts = pipeline_index.for_entry(entry)
        active = SeasonBoard::PipelineIndex.active_source(entry)
        entry.sources.filter_map do |source|
          path = source.review_path
          next unless path && File.file?(path)

          source_row(entry, source, path, facts && active&.base == source.base ? facts : nil)
        end
      end

      def source_row(entry, source, path, facts)
        state = facts&.state_and_detail
        @index.file_row(
          path, badges: badges(entry, source, path, state), primary: primary_action(entry, source, path, state),
                data_fix: data_fix_action(path), note: note_for(source)
        )
      end

      # == Badges

      def badges(entry, source, path, state)
        [layout_badge(source), content_badge(source), fin_badge(entry), phase_badge(source), staged_badge(path),
         state_badge(state)].compact
      end

      def layout_badge(source)
        label = if source.lt2_path && source.lt4_path then 'LT2 + LT4'
                elsif source.lt2_path then 'LT2'
                else 'LT4'
                end
        Badge.new(label:, tone: 'secondary')
      end

      def content_badge(source)
        key = if source.results? then :results
              elsif source.meeting_only? then :meeting_only
              else :no_results
              end
        Badge.new(label: I18n.t("sources.results.badges.#{key}"), tone: key == :results ? 'success' : 'secondary')
      end

      def fin_badge(entry)
        if entry.fin_event_id && off_board?(entry.fin_event_id)
          Badge.new(label: I18n.t('sources.results.badges.off_board', fin_event_id: entry.fin_event_id), tone: 'warning',
                    title: I18n.t('sources.results.badges.off_board_tooltip'))
        elsif entry.fin_event_id
          Badge.new(label: "FIN #{entry.fin_event_id}", tone: 'primary', title: I18n.t('sources.results.badges.board_row'),
                    path: SeasonBoard::ActionPaths.board_row_path(entry.fin_event_id))
        else
          Badge.new(label: I18n.t('sources.results.badges.non_fin'), tone: 'warning', title: I18n.t('sources.results.badges.non_fin_tooltip'))
        end
      end

      # True when the stored board summary of the season has no row with the FIN id (0.10.102: a meeting only on the
      # 'Eventi' calendar, or an adopted link no longer taken). Unknown (no stored summary, e.g. another season): false.
      def off_board?(fin_event_id)
        @board_ids = SeasonBoard::Snapshot.board_fin_event_ids(@index.season_id) unless defined?(@board_ids)
        @board_ids ? @board_ids.exclude?(fin_event_id) : false
      end

      def phase_badge(source)
        Badge.new(label: I18n.t('sources.results.badges.phase', phase: source.phase), tone: 'info') if source.in_review?
      end

      def staged_badge(path)
        count = sessions.for(path)&.staging_rows.to_i
        Badge.new(label: I18n.t('sources.results.badges.staged', count:), tone: 'info') if count.positive?
      end

      def state_badge(state)
        return unless state

        name, detail = state
        tone = { preparing: 'info', prepare_queued: 'info', prepare_failed: 'danger', needs_review: 'warning', ready_to_commit: 'success' }.fetch(name)
        label = WAITING_LABELS.key?(name) ? I18n.t(WAITING_LABELS[name]) : SeasonBoard::StateText.label(name, detail)
        Badge.new(label: label.truncate(80), tone:, title: label)
      end

      def note_for(source)
        I18n.t('sources.results.phase_files', count: source.phase_paths.size) if source.phase_paths.any?
      end

      # == Actions

      def primary_action(entry, source, path, state) # rubocop:disable Metrics/CyclomaticComplexity
        case state&.first
        when :preparing, :prepare_queued then waiting_action(state.first)
        when :ready_to_commit then commit_action(path)
        when :needs_review then review_action(path, state.last[:step])
        when :prepare_failed then entry.fin_event_id ? resume_or_open(source, path) : prepare_action(path, again: true)
        else entry.fin_event_id || source.in_review? ? resume_or_open(source, path) : prepare_action(path)
        end
      end

      # Disabled action of a source whose prepare is running (:preparing) or queued (:prepare_queued, 0.10.99: no second
      # click on "Prepare" / "Retry" while the first one waits).
      def waiting_action(name)
        RowAction.new(label: I18n.t(WAITING_LABELS.fetch(name)), path: nil, icon: name == :preparing ? 'fa-spinner' : 'fa-hourglass-half',
                      disabled: true)
      end

      def resume_or_open(source, path)
        return review_action(path, source.phase, resume: true) if source.in_review?

        RowAction.new(label: I18n.t('sources.results.actions.open'), icon: 'fa-wand-magic', kind: :data_fix,
                      path: @index.url_helpers.review_sessions_path(file_path: path, phase_v2: 1))
      end

      def review_action(path, step, resume: false)
        label = I18n.t(resume ? 'sources.results.actions.resume' : 'sources.results.actions.review', step:)
        RowAction.new(label:, icon: 'fa-list-check', kind: :data_fix,
                      path: SeasonBoard::ActionPaths.review_step_path(path, step, filter_state: resume ? nil : 'review'))
      end

      def commit_action(path)
        RowAction.new(label: I18n.t('season_board.actions.commit'), icon: 'fa-flag-checkered', kind: :data_fix,
                      path: @index.url_helpers.data_fix_commit_summary_path(file_path: path))
      end

      def prepare_action(path, again: false)
        RowAction.new(label: I18n.t(again ? 'sources.results.actions.retry_prepare' : 'sources.results.actions.prepare'),
                      icon: 'fa-gears', http_method: :post, path: @index.url_helpers.sources_prepare_path,
                      params: { path: @index.relative(path), season_id: @index.season_id },
                      confirm: I18n.t('sources.results.actions.prepare_confirm'))
      end

      def data_fix_action(path)
        RowAction.new(label: I18n.t('sources.results.actions.open'), icon: 'fa-wand-magic', kind: :data_fix,
                      path: @index.url_helpers.review_sessions_path(file_path: path, phase_v2: 1))
      end

      def pipeline_index
        @pipeline_index ||= SeasonBoard::PipelineIndex.new(season_id: @index.season_id)
      end

      def sessions
        @sessions ||= DataFix::SessionIndex.new(data_dir: @index.data_root)
      end
    end
  end
end
