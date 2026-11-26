# frozen_string_literal: true

module Sources
  #
  # = Sources::CleanupsController
  #
  # The clean-up page of the Sources season (0.10.104):
  # - GET /sources/cleanup: the dry run (Sources::Cleanup::Plan): what would move where and by which rule, what is
  #   listed only, what is kept and why; nothing is written;
  # - POST /sources/cleanup (digest, season_id): the operator's click (CSRF-checked form) applies it
  #   (Sources::Cleanup::Apply: plans again and refuses a different digest), then comes back here with a summary.
  # Nothing is ever deleted: the page says where each file goes and how to move it back.
  #
  class CleanupsController < BaseController
    helper_method :cleanup_crumbs

    # GET /sources/cleanup[?season_id=]
    def show
      @ops_ready = Ops.safely(false) { Ops.available? }
      @plan = Sources::Cleanup::Plan.new(season_id:, data_root:)
      backup = Sources::Cleanup.backup_placeholder(season_id)
      @folders = { backup:, duplicates: "#{backup}/#{Sources::Cleanup::DUPLICATES_FOLDER}", manifests: "manifests.done/#{season_id}",
                   calendars: "calendar.done/#{season_id}", moves_file: Sources::Cleanup::MOVES_FILE }
    end

    # POST /sources/cleanup
    def create
      result = Sources::Cleanup::Apply.new(season_id:, digest: params[:digest].to_s, data_root:).call
      level, message = summary(result)
      flash[level] = message
      redirect_to(sources_cleanup_path(season_id:), status: :see_other)
    end

    private

    # [flash level, message] for an Apply result.
    def summary(result)
      scope = 'sources.cleanup.flash'
      return [:warning, I18n.t("#{scope}.refused", reason: I18n.t("sources.cleanup.reasons.#{result.reason}"))] if result.refused?

      counts = { moved: result.moved.size, skipped: result.skipped.size, folder: result.backup_dir.to_s }
      return [:warning, I18n.t("#{scope}.failed", error: result.error, **counts)] if result.error

      [:notice, I18n.t("#{scope}.done", **counts)]
    end

    # Breadcrumbs: Import > Sources > Clean up.
    def cleanup_crumbs
      [[I18n.t('shell.groups.import'), nil], [I18n.t('sources.nav'), sources_results_path(season_id:)], [I18n.t('sources.cleanup.nav'), nil]]
    end
  end
end
