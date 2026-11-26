# frozen_string_literal: true

#
# = OperationsController
#
# /operations (phase 11): the maintenance operations (Maintenance::Registry), the read-only inspectors (13) and their run history
# (OperationRunsGrid, ops DB); /operations/:key/new: the operation form, prefilled from a health finding
# (+finding_id+, Maintenance::Operation.from_finding) or from explicit params (e.g. the commit report links). The form
# posts to Maintenance::RunsController#create, which queues the dry run. Reads only the local DB and the ops DB.
#
# POST operations/switch: the 'operations.enabled' switch (Maintenance.store_enabled!, an 'operations.switched' event),
# from the dashboard system column (+return_to+ 'dashboard': a Turbo request is answered with a turbo stream replacing
# the switch and the toasts) or from the /operations header (+return_to+ 'operations': always redirected back, the
# whole page depends on the setting).
#
class OperationsController < ApplicationController
  PER_PAGE = 30

  before_action :set_operation_class, only: :new

  # GET /operations
  def index
    @operations = Maintenance::Registry.all
    @inspectors = Maintenance::Registry.inspectors
    @ops_available = Ops.available?
    @enabled = Maintenance.enabled?
    return unless @ops_available

    @grid = OperationRunsGrid.new(grid_params)
    @assets = @grid.assets.page(params[:page]).per(PER_PAGE)
  end

  # GET /operations/:key/new
  #
  # == Params
  # - finding_id: an Ops::HealthFinding fixed by the operation (prefills the params, origin 'health');
  # - the operation params (prefill), origin ('commit_report' for the commit report links).
  def new
    @finding = find_finding
    @operation = if @finding
                   @operation_class.from_finding(@finding)
                 else
                   @operation_class.new(**@operation_class.permitted(params))
                 end
    @origin = origin_for(@finding)
  end

  # POST /operations/switch (+value+ 1 | 0, +return_to+ dashboard | operations)
  def switch
    messages = switch_messages(params[:value].to_s == '1')
    # (html first: the answer to an Accept '*/*' request)
    respond_to do |format|
      format.html { redirect_with(messages) }
      format.turbo_stream do
        next redirect_with(messages) unless params[:return_to].to_s == 'dashboard'

        messages.each { |key, text| flash.now[key] = text } # (shown by this response only)
        render(:switch)
      end
    end
  end

  protected

  # The switch reads and writes the local ops DB only: reachable from the dashboard of an API-offline session too.
  def api_offline_allowed?
    action_name == 'switch'
  end

  private

  # Stores the setting (with the ops DB); returns the flash messages (Hash key => text) of the outcome.
  def switch_messages(value)
    return { warning: t('maintenance.switch.flash.ops_unavailable') } unless Ops.available?
    return { error: t('maintenance.switch.flash.store_failed') } if Maintenance.store_enabled!(value, user_id: current_user&.id).nil?

    { info: t(value ? 'maintenance.switch.flash.on' : 'maintenance.switch.flash.off') }
  end

  # Back to the dashboard system column or to /operations, with the messages.
  def redirect_with(messages)
    messages.each { |key, text| flash[key] = text }
    redirect_to(params[:return_to].to_s == 'dashboard' ? "#{root_path}#dashboard-system" : operations_path)
  end

  def set_operation_class
    @operation_class = Maintenance::Registry.find(params.expect(:key))
    return if @operation_class

    flash[:error] = t('maintenance.errors.unknown_operation')
    redirect_to(operations_path)
  end

  # The finding of params[:finding_id] when the operation fixes its check (nil otherwise).
  def find_finding
    return if params[:finding_id].blank?

    finding = Ops.safely { Ops::HealthFinding.find_by(id: params[:finding_id]) if Ops.available? }
    finding if finding && @operation_class.fixes.include?(finding.check_key)
  end

  def origin_for(finding)
    return 'health' if finding
    return 'commit_report' if params[:origin].to_s == 'commit_report'

    'ui'
  end

  def grid_params
    @grid_params ||= params.fetch(:operation_runs_grid, {}).permit(:operation_key, :mode, :status, :season_id, :order, :descending)
  end
  helper_method :grid_params
end
