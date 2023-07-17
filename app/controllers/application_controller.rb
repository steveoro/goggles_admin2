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
    unless GogglesDb::GrantChecker.admin?(current_user)
      logger.debug('* Not an Admin!')
      sign_out(current_user)
      flash[:error] = I18n.t('dashboard.not_admin_error')
      redirect_to new_user_session_path && return
    end

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
  # - <tt>endpoint_name</tt>: the actual API endpoint for the deletion
  #                           (i.e. GogglesDb::User => 'DELETE /user/:id')
  # - <tt>row_ids</tt>: array of row IDs to be deleted
  #
  # == Returns:
  # - an array of row IDs that raised errors, or an empty list otherwise.
  #
  def delete_rows!(endpoint_name, row_ids)
    error_ids = []
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

  # Strong parameters checking for /index, including pass-through from modal editors
  # given a specific datagrid_name.
  #
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params_for(datagrid_name)
    @index_params = params.permit(:page, :per_page, datagrid_name)
    return @index_params.merge(params.fetch(datagrid_name, {}).permit!) if params[datagrid_name].respond_to?(:fetch)

    # Assuming the pass-through filtering parameters for the grid are a valid JSONified
    # string, we'll parse them to rebuild the grid filters:
    # (both boxed & unboxed params are currently needed)
    pass_through = @index_params[datagrid_name].is_a?(String) ? JSON.parse(@index_params[datagrid_name]) : {}
    @index_params.merge(pass_through).merge(datagrid_name => pass_through).permit!
  end

  # Returns the sub-hash of namespaced params according to the specified <tt>namespace</tt>
  # (using <tt>require()</tt>), or the params Hash itself when no namespace is given.
  #
  # == Params:
  # - <tt>namespace</tt>: the 'require' namespace to be used for filtering the parameters
  def namespaced_params(namespace)
    return params if namespace.nil?

    params.require(namespace)
  end

  # Generalized parameters strong-checking for grid row update.
  #
  # == Params:
  # - <tt>model_class</tt>: the actual model class (sibling of ActiveRecord::Base) source of the attributes
  #                         for the PUT/POST API action
  def edit_params(model_class, namespace = nil)
    namespaced_params(namespace).permit(
      model_class.new
                 .attributes.keys
                 .reject { |key| key == 'lock_version' } +
                 %w[_method authenticity_token]
    )
  end

  # Generalized parameters strong-checking for grid row create.
  #
  # == Params:
  # - <tt>model_class</tt>: the actual model class (sibling of ActiveRecord::Base) source of the attributes
  #                         for the PUT/POST API action
  def create_params(model_class, namespace = nil)
    namespaced_params(namespace).permit(
      model_class.new
                 .attributes.keys
                 .reject { |key| key == 'lock_version' }
    )
  end
  #-- -------------------------------------------------------------------------
  #++

  # Whitelisted datagrid model attributes (and values) for a domain collection
  # used as base data for a grid.
  #
  # == Params:
  # - <tt>model_class</tt>: the model class to be used for the whitelist
  # - <tt>attrs</tt>: the attribute hash that has to be filtered of unsupported columns
  #
  # == Returns:
  # The filtered attribute hash
  #
  def datagrid_model_attributes_for(model_class, attrs)
    allowed_keys = model_class.new.model_attributes.keys
    attrs.select { |key, _value| allowed_keys.include?(key) }
  end
  #-- -------------------------------------------------------------------------
  #++

  # Checks the <tt>result.code</tt> and returns the <tt>result.body</tt> assuming it's a valid JSON string.
  # Returns an empty Hash otherwise.
  def parse_json_result_from_create(result)
    return {} unless result.respond_to?(:code) && result.respond_to?(:body) &&
                     result.code >= 200 && result.code < 300 && result.body.present?

    JSON.parse(result.body)
  end
  #-- -------------------------------------------------------------------------
  #++

  # Prepares the grid domain and its counters using the already parsed response data and
  # the target grid & model class.
  #
  # == Params:
  # - <tt>grid_class</tt>, the target grid class
  # - <tt>model_class</tt>, the target model class
  # - <tt>api_response_headers</tt>, response#headers returned by the API call
  # - <tt>parsed_response</tt>, the Hash wrapping the JSON response data from the API call
  #
  # == Setter for:
  # - <tt>@domain_count</tt>, total row count for this domain
  # - <tt>@domain_page</tt>, current page number in the domain
  # - <tt>@domain_per_page</tt>, total rows per page
  # - <tt>@domain</tt>, actual domain of model instances for the grid
  #
  def set_grid_domain_for(grid_class, model_class, api_response_headers, parsed_response)
    @domain_count = api_response_headers[:total].to_i
    @domain_page = api_response_headers[:page].to_i
    @domain_per_page = api_response_headers[:per_page].to_i

    # Setup grid domain converting the Hash into temp models for better handling:
    @domain = parsed_response.map { |attrs| model_class.new(datagrid_model_attributes_for(model_class, attrs)) }

    # Setup datagrid:
    grid_class.data_domain = @domain
  end

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
