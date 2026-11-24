# frozen_string_literal: true

#
# = OperationsController
#
# /operations (phase 11): the maintenance operations (Maintenance::Registry) and their run history
# (OperationRunsGrid, ops DB); /operations/:key/new: the operation form, prefilled from a health finding
# (+finding_id+, Maintenance::Operation.from_finding) or from explicit params (e.g. the commit report links). The form
# posts to Maintenance::RunsController#create, which queues the dry run. Reads only the local DB and the ops DB.
#
class OperationsController < ApplicationController
  PER_PAGE = 30

  before_action :set_operation_class, only: :new

  # GET /operations
  def index
    @operations = Maintenance::Registry.all
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

  private

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
