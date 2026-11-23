# frozen_string_literal: true

#
# = RemoteWritesController
#
# /remote_writes: log of the API calls made by admin2 that may have changed the remote data
# (Ops::RemoteWrite: every APIProxy call but GET, the sign-in and the SQL batch push), with the drift v0
# verdict for the configured API and its "Acknowledge" button.
#
# Reads only the local ops DB (no API call): reachable from API-offline sessions.
#
class RemoteWritesController < ApplicationController
  PER_PAGE = 50

  # GET /remote_writes
  #
  # == Assigns:
  # - <tt>@drift</tt>: Drift::V0Status for the configured API;
  # - <tt>@ops_available</tt>: false when the ops DB is not ready (no grid then);
  # - <tt>@grid</tt>: the RemoteWritesGrid; <tt>@assets</tt>: its current page.
  def index
    @api_url = APIProxy.configured_base_url.to_s.delete_suffix('/')
    @drift = Drift::V0Status.for(@api_url)
    @ops_available = Ops.available?
    @grid = RemoteWritesGrid.new(grid_filter_params) if @ops_available

    respond_to do |format|
      format.html { @assets = @grid.assets.page(params[:page]).per(PER_PAGE) if @grid }
      format.csv do
        next head(:service_unavailable) unless @grid

        send_data(@grid.to_csv, type: 'text/csv', disposition: 'inline',
                                filename: "remote-writes-#{Time.current.strftime('%Y%m%d.%H%M%S')}.csv")
      end
    end
  end

  # POST /remote_writes/acknowledge
  # Marks every remote write logged so far as reviewed (Ops::Setting 'drift.acknowledged_at'):
  # drift v0 stops warning about them.
  def acknowledge
    if Ops.safely(false) { Ops.available? && Ops::RemoteWrite.acknowledge!.present? }
      flash[:info] = t('.done')
    else
      flash[:error] = t('.failed')
    end
    redirect_to(remote_writes_path)
  end

  protected

  # The page reads only the local ops DB.
  def api_offline_allowed?
    true
  end

  # Datagrid filter parameters (memoized: used by the view).
  def grid_filter_params
    @grid_filter_params ||= params.fetch(:remote_writes_grid, {}).permit(:endpoint, :status, :http_method, :base_url,
                                                                         :order, :descending)
  end
end
