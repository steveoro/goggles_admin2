# frozen_string_literal: true

#
# = Auto-complete (DB-lookup) component
#
#   - version:  7.0.3.33
#   - author:   Steve A.
#
# Allows a search query on a DB-lookup entity by any field
# in order to retrieve its ID.
#
# Allows direct edit of both the ID and its search value; includes
# a descriptive label text that remains visibile after the search/lookup.
#
# Works even on Bootstrap modals.
#
class AutoCompleteComponent < ViewComponent::Base
  # Creates a new ViewComponent
  #
  # == Options
  # - <tt>:base_api_url</tt>:
  #  base API URL for data request (w/o endpoint or params)
  #  (*required*)
  #
  # - <tt>:detail_endpoint</tt>:
  #   API endpoint name used to retrieve additional or initial Entity details;
  #   this can be left unset if the additional detail retrieval API call doesn't need to be done.
  #   (i.e.: model 'SwimmingPool' => detail API: 'swimming_pool' => resulting endpoint: '<baseApiUrlValue>/swimming_pool/<ID>')
  #
  # - <tt>:base_name</tt>:
  #   base downcase entity name; needed only when <tt>:detail_endpoint</tt> is left +nil+.
  #
  # - <tt>:search_endpoint</tt>:
  #   API endpoint name for the actual autocomplete search.
  #  (i.e.: model 'User' => search API: 'users' => resulting endpoint: '<baseApiUrlValue>/users?<SEARCH_QUERY>')
  #  (*required*)
  #
  # - <tt>:search_column</tt>:
  #   query field name used in the API search call; defaults to 'name';
  #
  # - <tt>:label_column</tt>:
  #   field name used to retrieve additional label/description for the results; defaults to 'description';
  #
  # - <tt>:label2_column</tt>:
  #   secondary field name used as additional description (#2) appended to the above;
  #
  # - <tt>:jwt</tt>:
  #   current_user.jwt (assumes 'current_user' is currently logged-in and valid)
  #
  def initialize(options = {})
    super
    @base_api_url = options[:base_api_url]
    @detail_endpoint = options[:detail_endpoint]
    @base_name = options[:base_name]
    @search_endpoint = options[:search_endpoint]
    @search_column = options[:search_column]
    @label_column = options[:label_column]
    @label2_column = options[:label2_column]
    @jwt = options[:jwt]
  end

  # Skips rendering unless the required parameters are set
  def render?
    @base_api_url.present? && (@detail_endpoint.present? || @base_name.present?) &&
      @search_endpoint.present? && @jwt.present?
  end
end
