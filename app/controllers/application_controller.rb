# frozen_string_literal: true

require 'version'

# = ApplicationController
#
# Common parent controller
class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception
  before_action :app_settings_row, :set_locale, :detect_device_variant,
                :check_jwt_session, :authenticate_user!

  protected

  # Memoize base app settings
  def app_settings_row
    @app_settings_row ||= GogglesDb::AppParameter.versioning_row
  end

  # Checks JWT validity and forces a new sign-in otherwise.
  def check_jwt_session
    redirect_to new_user_session_path && return unless GogglesDb::GrantChecker.admin?(current_user)

    # JWT expired? Force a new log-in to get a fresh one:
    decoded_jwt = GogglesDb::JWTManager.decode(current_user.jwt, Rails.application.credentials.api_static_key)
    return unless decoded_jwt.nil?

    logger.debug('* JWT expired: forcing new sign-in...')
    sign_out(current_user)
    redirect_to new_user_session_path && return
  end
  #-- -------------------------------------------------------------------------
  #++

  # Deletes the specified list of rows, returning the list or row IDs that raised errors,
  # or an empty array if everything went fine.
  #
  # == Params:
  # - <tt>model_class</tt>: the actual model class (sibling of ActiveRecord::Base) related to the API endpoint for the deletion
  #                         (i.e. GogglesDb::User => 'DELETE /user/:id')
  # - <tt>row_ids</tt>: array of row IDs to be deleted
  #
  # == Returns:
  # - an array of row IDs that raised errors, or an empty list otherwise.
  # - will skip the whole deletion unless <tt>model_class</tt> responds to <tt>#table_name</tt>.
  #
  def delete_rows!(model_class, row_ids)
    error_ids = []
    endpoint_name = "#{model_class.table_name.singularize}"
    return row_ids unless model_class.respond_to?(:table_name)

    row_ids.each do |row_id|
      result = APIProxy.call(
        method: :delete,
        url: "#{endpoint_name}/#{row_id}",
        jwt: current_user.jwt
      )

      if result.code != 200 || result.body != 'true'
        logger.error("\r\n*** ERROR: API 'DELETE /#{endpoint_name}/#{row_id}'")
        logger.error(result.inspect)
        error_ids << row_id
      end
    end
    error_ids
  end

  # Parameters strong-checking for grid row(s) delete
  def delete_params
    params.permit(:id, :ids, :_method, :authenticity_token)
  end
  #-- -------------------------------------------------------------------------
  #++

  # Generalized parameters strong-checking for grid row create/update.
  #
  # == Params:
  # - <tt>model_class</tt>: the actual model class (sibling of ActiveRecord::Base) source of the attributes
  #                         for the PUT/POST API action
  def edit_params(model_class)
    params.permit(
      model_class.new
                 .attributes.keys
                 .reject { |key| %w[lock_version created_at updated_at].include?(key) } +
                 %i[_method authenticity_token]
    )
  end
  #-- -------------------------------------------------------------------------
  #++

  private

  # Sets the current application locale given the :locale request parameter or
  # the existing cookie value. Falls back on the default locale instead.
  #
  # The cookie :locale will be updated each time; the locale value is checked
  # against the defined available locales.
  #
  # == Precedence:
  #
  # 1. params[:locale]
  # 2. cookies[:locale]
  # 3. I18n.default_locale
  #
  # rubocop:disable Metrics/PerceivedComplexity
  def set_locale
    # NOTE: in order to avoid DOS-attacks by creating ludicrous amounts of Symbols,
    # create a string map of the available locales and set the I18n.locale only
    # when the string parameter actually belongs to this set.

    # Memoize the list of available/acceptable locales (this won't change unless server is restarted):
    @accepted_locales ||= I18n.available_locales.map(&:to_s)

    locale = params[:locale] if @accepted_locales.include?(params[:locale])
    if locale.nil?
      # Use the cookie only when set or enabled:
      locale = cookies[:locale] if @accepted_locales.include?(cookies[:locale])
    else
      # Store the chosen locale when it changes
      cookies[:locale] = locale
    end

    current_locale = locale || I18n.default_locale # (default case when cookies are disabled)
    return unless @accepted_locales.include?(current_locale.to_s)

    I18n.locale = current_locale.to_sym
    logger.debug("* Locale is now set to '#{I18n.locale}'")
  end
  # rubocop:enable Metrics/PerceivedComplexity
  #-- -------------------------------------------------------------------------
  #++

  # Sets the internal @browser instance used to detect 'request.variant' type
  # depending on 'request.user_agent'.
  # (In order to be processed by Rails, customized layouts and views will be given
  #  a "+<VARIANT>.EXT" suffix.)
  #
  # @see https://github.com/fnando/browser
  def detect_device_variant
    # Detect browser type:
    @browser = Browser.new(request.user_agent)
    request.variant = :mobile if @browser.device.mobile? && !@browser.device.tablet?
    # Add here more variants when needed:
    # request.variant = :tablet if @browser.device.tablet?
    # request.variant = :desktop if @browser.device.ipad?
  end
  #-- -------------------------------------------------------------------------
  #++
end
