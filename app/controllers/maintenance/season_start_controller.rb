# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::SeasonStartController
  #
  # The season-start checklist (phase 13, Maintenance::SeasonStart::Checklist):
  # - index (GET /operations/season_start): pick the season (latest FIN Masters seasons, the next id);
  # - show (GET /operations/season_start/:season_id): the eight ordered steps, read on every view (no API call);
  # - step (POST /operations/season_start/:season_id/steps/:step_key, +perform+): the action of one step, REFUSED when
  #   the step is not ready (a previous step is neither done nor skipped), when it is already done from the data, or
  #   when the step has no such action:
  #   confirm / skip / reopen (the tick boxes 3 and 7; reopen also undoes a skip), upload (4: the source file into
  #   crawler/data/standard_timings/<season>/), operation (5, 8: opens the prefilled dry run form), repair (2: the
  #   'categories.clone' form, only when offered), check_remote (6: GET season/:id on the configured API, then the
  #   held standard-timings scripts of the season are released for push).
  # Every write goes to the ops DB (Ops::SeasonChecklistItem) or the Outbox (release); no Season row is ever created.
  #
  class SeasonStartController < ApplicationController
    UPLOAD_EXTENSIONS = %w[.xlsx .csv].freeze
    LATEST_SEASONS = 3

    before_action :require_ops!, only: :step
    before_action :set_checklist, only: %i[show step]

    # GET /operations/season_start
    def index
      @latest = GogglesDb::Season.where(season_type_id: GogglesDb::SeasonType.mas_fin&.id).order(id: :desc).limit(LATEST_SEASONS).to_a
      @next_id = @latest.first ? @latest.first.id + 10 : nil
      redirect_to(season_start_path(params[:season_id].to_i)) if params[:season_id].to_i.positive?
    end

    # GET /operations/season_start/:season_id
    def show
      @ops_available = Ops.available?
    end

    # POST /operations/season_start/:season_id/steps/:step_key
    def step
      step = @checklist.step(params[:step_key])
      return refuse(:unknown_step) unless step

      perform = params[:perform].to_s
      return refuse(:no_action) unless performable?(step, perform)
      return reopen(step) if perform == 'reopen'
      return refuse(:not_ready) unless step.ready?
      return refuse(:already_done) if step.done? && step.from_data?

      send("perform_#{perform}", step)
    end

    private

    def require_ops!
      return if Ops.available?

      flash[:error] = t('maintenance.errors.ops_unavailable')
      redirect_to(season_start_path(params[:season_id].to_i))
    end

    def set_checklist
      @checklist = Maintenance::SeasonStart::Checklist.new(season_id: params[:season_id])
    end

    def back(level, key, **options)
      flash[level] = t("maintenance.season_start.flash.#{key}", **options)
      redirect_to(season_start_path(@checklist.season_id, anchor: "season-start-#{params[:step_key]}"))
    end

    def refuse(key) = back(:error, key)

    # The actions each step accepts.
    def performable?(step, perform) # rubocop:disable Metrics/CyclomaticComplexity
      case perform
      when 'confirm', 'skip' then step.kind == :operator
      when 'reopen' then step.kind == :operator && step.item.present? && !step.item.pending?
      when 'upload' then step.key == 'standard_timings_file'
      when 'check_remote' then step.key == 'remote_season'
      when 'operation' then step.action == :operation
      when 'repair' then step.key == 'category_types'
      else false
      end
    end

    def perform_confirm(step) = store(step, 'done', :done)
    def perform_skip(step) = store(step, 'skipped', :skipped)

    def reopen(step)
      store(step, 'pending', :reopened)
    end

    def store(step, status, flash_key)
      item = Ops::SeasonChecklistItem.for_step(@checklist.season_id, step.key)
      item.update!(status:, note: params[:note].to_s.strip.truncate(500).presence || item.note,
                   done_by: status == 'pending' ? nil : current_user&.id, done_at: status == 'pending' ? nil : Time.current)
      back(:info, flash_key)
    end

    # (step 5 and 8) the prefilled dry run form of the step's operation
    def perform_operation(step)
      redirect_to(new_operation_path(key: step.operation['key'], **step.operation['params'].symbolize_keys))
    end

    # (step 2) the 'categories.clone' form, only when the checklist offers the repair
    def perform_repair(step)
      return refuse(:repair_not_offered) unless step.action == :repair

      perform_operation(step)
    end

    # (step 4) the source file, saved in crawler/data/standard_timings/<season id>/ (basename only, .xlsx or .csv)
    def perform_upload(step) # rubocop:disable Metrics/AbcSize
      file = params[:file]
      name = File.basename(file.respond_to?(:original_filename) ? file.original_filename.to_s : '').gsub(/[^\w.-]/, '_')
      return refuse(:upload_invalid) if name.blank? || UPLOAD_EXTENSIONS.exclude?(File.extname(name).downcase)

      folder = @checklist.standard_timings_folder
      FileUtils.mkdir_p(folder)
      path = folder.join(name)
      return refuse(:upload_invalid) unless path.expand_path.to_s.start_with?(folder.expand_path.to_s)

      FileUtils.cp(file.path, path)
      Ops::SeasonChecklistItem.for_step(@checklist.season_id, step.key)
                              .update!(status: 'done', note: name, done_by: current_user&.id, done_at: Time.current)
      back(:info, :uploaded, file: name, folder: Outbox.relative_path(folder, data_root: Rails.root))
    end

    # (step 6) GET season/:id on the configured API; when it exists, the held standard-timings scripts are released
    def perform_check_remote(step) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      result = APIProxy.call(method: :get, url: "season/#{@checklist.season_id}", jwt: current_user&.jwt, open_timeout: 5, timeout: 20)
      item = Ops::SeasonChecklistItem.for_step(@checklist.season_id, step.key)
      return back(:error, :remote_unreachable, error: result.error_detail.to_s.truncate(300)) if result.unreachable?

      if result.code == 200 && result.json.is_a?(Hash) && result.json['id'].to_i == @checklist.season_id
        released = @checklist.held_scripts.count { |script| release(script) }
        item.update!(status: 'done', note: nil, done_by: current_user&.id, done_at: Time.current)
        return back(:info, :remote_found, count: released)
      end

      item.update!(status: 'pending', done_at: nil,
                   note: t('maintenance.season_start.steps.remote_season.checked', when: l(Time.current, format: :short),
                                                                                   result: t('maintenance.season_start.steps.remote_season.not_found')))
      return back(:warning, :remote_missing, id: @checklist.season_id) if result.code == 404

      back(:error, :remote_error, code: result.code, error: result.json.is_a?(Hash) ? result.json['error'].to_s.truncate(200) : '')
    end

    def release(script)
      Outbox::ScriptActions.release!(script)
      true
    rescue Ops::SqlScript::InvalidTransition => e
      Rails.logger.warn("[SeasonStart] script #{script.id} not released: #{e.message}")
      false
    end
  end
end
