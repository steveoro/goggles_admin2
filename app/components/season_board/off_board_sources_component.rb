# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::OffBoardSourcesComponent
  #
  # The pending sources of the board season whose FIN id is on no board row (Builder::Result#off_board_sources,
  # 0.10.102: a meeting listed only on the FIN 'Eventi' calendar, or an adopted link gone since), listed under the
  # board next to the unmatched sources (0.10.103, replacing the board warning). Nothing prepares them by itself; each
  # line offers the actions of an unmatched source: "Open in Sources" (the file focused in its tab), "Open in Data-Fix"
  # (a source to review) and the opt-in "Prepare" (POST sources/prepare: phases 1-5 in the background, never a
  # commit), disabled while a preparation is queued or running. Its pipeline state, when it has one, is a badge.
  #
  class OffBoardSourcesComponent < ViewComponent::Base
    # Pipeline state => badge class.
    STATE_CSS = { preparing: 'text-bg-info', prepare_queued: 'text-bg-info', prepare_failed: 'text-bg-danger',
                  needs_review: 'text-bg-warning', ready_to_commit: 'text-bg-success' }.freeze
    WAITING_LABELS = { preparing: 'pipeline_automation.stages.preparing', prepare_queued: 'season_board.activity.prepare_queued' }.freeze

    # == Params:
    # - entries: Array of SeasonBoard::DiskIndex::Entry (with a FIN id);
    # - pipeline: Hash of base => SeasonBoard::PipelineIndex::Facts (Builder::Result#unmatched_pipeline);
    # - season_id: the board season; csrf_token: the page token (the forms are rendered without their own);
    # - data_root: base 'crawler/data' folder (default: Sources.data_root).
    # The component of a Builder::Result (its off-board sources and their pipeline facts).
    def self.from_board(board, csrf_token: nil)
      new(entries: board.off_board_sources, season_id: board.season&.id, pipeline: board.unmatched_pipeline, csrf_token:)
    end

    def initialize(entries:, season_id:, pipeline: {}, csrf_token: nil, data_root: nil)
      super()
      @entries = Array(entries)
      @pipeline = pipeline || {}
      @season_id = season_id
      @csrf_token = csrf_token
      @data_root = Pathname.new(data_root || Sources.data_root)
    end

    def render?
      @entries.any?
    end

    protected

    attr_reader :entries, :csrf_token, :season_id

    # The newest source of the entry (the review one first), or nil.
    def source_of(entry)
      entry.review_source || entry.sources.max_by { |src| src.mtime.to_f }
    end

    # The file shown in Sources: the source to review, else the first pending file.
    def main_path(entry)
      source_of(entry)&.review_path || entry.sql_new_paths.first || entry.manifest_pdf_paths.first
    end

    def sources_path(entry)
      Sources::Paths.focus_path(main_path(entry).to_s, season_id:, root: @data_root)
    end

    def pending_label(entry)
      key = if entry.review_source then :in_review
            elsif entry.sources.any? then :source
            elsif entry.sql_pending? then :sql
            else :manifest
            end
      t("season_board.off_board.pending.#{key}", phase: entry.phase)
    end

    # [state Symbol, label] of the entry's pipeline facts, or nil.
    def pipeline_state(entry)
      state, detail = @pipeline[entry.bases.first]&.state_and_detail
      return nil unless state

      label = WAITING_LABELS.key?(state) ? t(WAITING_LABELS[state]) : SeasonBoard::StateText.label(state, detail)
      [state, label.truncate(80)]
    end

    def state_css(state) = STATE_CSS.fetch(state, 'text-bg-secondary')

    def data_fix_path(entry)
      path = source_of(entry)&.review_path
      review_sessions_path(file_path: path.to_s, phase_v2: 1) if path
    end

    # The relative path posted by "Prepare" (a JSON source of results.new only), or nil.
    def prepare_path(entry)
      path = source_of(entry)&.review_path
      return nil unless path && File.extname(path.to_s) == '.json'

      Pathname.new(path.to_s).relative_path_from(@data_root).to_s
    rescue ArgumentError
      nil
    end

    def preparing?(entry)
      %i[preparing prepare_queued].include?(pipeline_state(entry)&.first)
    end
  end
end
