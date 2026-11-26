# frozen_string_literal: true

#
# = AutomationController
#
# The kill switches of the pipeline automation (phase 10, DataFix::Automation), toggled from the dashboard system
# column and from the Season board header: POST automation/switch with +switch+ (enabled | auto_extract |
# auto_prepare | auto_calendar) and +value+ (1 | 0). Each toggle writes an 'automation.switched' event; the ADMIN2_AUTOMATION=0
# environment override cannot be changed from here.
#
# A Turbo request (the switches, Switch::ToggleFormComponent) is answered with a turbo stream replacing both switch
# panels ('automation-switches-dashboard', 'automation-switches-season_board'), the board's automation badge and
# "Prepare all" button, and the toasts: the page stays as it is (the board filters, its open <details>). Any other
# request is redirected back to +return_to+ (the dashboard or the board).
#
class AutomationController < ApplicationController
  RETURN_PATHS = %w[dashboard season_board].freeze
  # Switches deciding whether the FIN change alert may stay hidden (0.10.103: FedernuotoWatch::Progress): toggling one
  # drops the stored progress and shows the alert again in every tab until the next planner pass.
  FIN_ALERT_SWITCHES = %w[enabled auto_calendar].freeze

  # [POST] automation/switch
  def switch
    messages = switch_messages(params[:switch].to_s)
    # (html first: the answer to an Accept '*/*' request)
    respond_to do |format|
      format.html do
        messages.each { |key, text| flash[key] = text }
        redirect_to(return_path)
      end
      format.turbo_stream do
        messages.each { |key, text| flash.now[key] = text } # (shown by this response only)
        render(:switch)
      end
    end
  end

  protected

  # The switches are reachable in an API-offline session too (they read and write the local ops DB only).
  def api_offline_allowed?
    true
  end

  private

  # Stores the switch (when known and the ops DB is there); returns the flash messages (Hash key => text) of the outcome.
  def switch_messages(switch)
    return { error: I18n.t('pipeline_automation.flash.unknown_switch', switch:) } if DataFix::Automation::SWITCHES.map(&:to_s).exclude?(switch)
    return { warning: I18n.t('pipeline_automation.flash.ops_unavailable') } unless Ops.available?

    value = params[:value].to_s == '1'
    label = I18n.t("pipeline_automation.switches.#{switch}.label")
    return { error: I18n.t('pipeline_automation.flash.store_failed', switch: label) } if DataFix::Automation.store!(switch, value, user_id: current_user&.id).nil?

    reset_fin_alert(switch)
    messages = { info: I18n.t("pipeline_automation.flash.switch_#{value ? 'on' : 'off'}", switch: label) }
    messages[:warning] = I18n.t('pipeline_automation.flash.env_override') if DataFix::Automation.env_off?
    messages
  end

  # (the FIN change alert shows again at once in every tab when a switch it depends on is toggled; never raises)
  def reset_fin_alert(switch)
    FedernuotoWatch::Progress.reset! if FIN_ALERT_SWITCHES.include?(switch)
  end

  def return_path
    params[:return_to].to_s == 'season_board' ? season_board_path : "#{root_path}#dashboard-system"
  end
end
