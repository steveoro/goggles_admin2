# frozen_string_literal: true

#
# = AutomationController
#
# The kill switches of the pipeline automation (phase 10, DataFix::Automation), toggled from the dashboard system
# column and from the Season board header: POST automation/switch with +switch+ (enabled | auto_extract |
# auto_prepare) and +value+ (1 | 0). Each toggle writes an 'automation.switched' event; the ADMIN2_AUTOMATION=0
# environment override cannot be changed from here. Redirects back to +return_to+ (the dashboard or the board).
#
class AutomationController < ApplicationController
  RETURN_PATHS = %w[dashboard season_board].freeze

  # [POST] automation/switch
  def switch
    switch = params[:switch].to_s
    if DataFix::Automation::SWITCHES.map(&:to_s).exclude?(switch)
      flash[:error] = I18n.t('pipeline_automation.flash.unknown_switch', switch:)
    elsif !Ops.available?
      flash[:warning] = I18n.t('pipeline_automation.flash.ops_unavailable')
    else
      store_switch(switch, params[:value].to_s == '1')
    end
    redirect_to(return_path)
  end

  protected

  # The switches are reachable in an API-offline session too (they read and write the local ops DB only).
  def api_offline_allowed?
    true
  end

  private

  def store_switch(switch, value)
    DataFix::Automation.store!(switch, value, user_id: current_user&.id)
    flash[:info] = I18n.t("pipeline_automation.flash.switch_#{value ? 'on' : 'off'}", switch: I18n.t("pipeline_automation.switches.#{switch}.label"))
    flash[:warning] = I18n.t('pipeline_automation.flash.env_override') if DataFix::Automation.env_off?
  end

  def return_path
    params[:return_to].to_s == 'season_board' ? season_board_path : "#{root_path}#dashboard-system"
  end
end
