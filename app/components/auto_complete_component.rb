# frozen_string_literal: true

#
# = Auto-complete (DB-lookup) component
#
#   - version:  7-0.3.52
#   - author:   Steve A.
#
# Allows a search query on a DB-lookup entity by any field in order to retrieve its ID and a descriptive label,
# together with other two additional & optional fields.
#
# Supports both in-line & remote data providers for the search.
#
# If the remote search is enabled (by setting the base API URL value), a second optional
# API call can be configured to retrieve all the detail fields using the currently selected entity ID.
#
# Allows direct edit of both the ID and its search value; includes
# a descriptive label text that remains visibile after the search/lookup.
#
# Works even on Bootstrap modals (the Select2-based DBLookup custom component doesn't).
# When used inside a form, same-named fields can be isolated within a namespace just by setting
# a custom value to the <tt>base_dom_id</tt> parameter.
#
class AutoCompleteComponent < ViewComponent::Base
  # Creates a new ViewComponent
  #
  # == Options
  # - <tt>base_dom_id</tt>: defines the base string name for the DOM ID used by the modal container,
  #   its input form (<tt>"frm-<BASE_MODAL_DOM_ID>"</tt>), its title label (<tt>"<BASE_MODAL_DOM_ID>-modal-title"</tt>)
  #   and its own POST button (<tt>"btn-<BASE_MODAL_DOM_ID>-submit-save"</tt>); defaults to "grid-edit".
  #
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
  #   query field name used in the API search call.
  #
  # - <tt>:search2_column</tt>:
  #   secondary filter/query field name used in the API search call;
  #   this affects only the list filtering for the search endpoint (can be used to better refine the rows found);
  #   defaults to +nil+.
  #
  # - <tt>:search2_dom_id</tt>:
  #   DOM ID for the secondary search field value; the referred node should contain the secondary filter/query value,
  #   if the search2 column is defined (defaults to +nil+).
  #
  # - <tt>:label_column</tt>:
  #   field name used to retrieve additional label/description for the results; defaults to 'description';
  #
  # - <tt>:label2_column</tt>:
  #   additional field name used as description (#2) appended to the above;
  #
  # - <tt>:target2_field</tt>:
  #   secondary target field name; field that shall be updated with the result value from the search.
  #   Totally optional: skipped when not set (default: null).
  #
  # - <tt>:target2_column</tt>:
  #   column or property name used as to set the value of the secondary target field;
  #   (totally optional, skipped when not set)
  #
  # - <tt>:target3_field</tt>:
  #   tertiary target field name;
  #   Managed as above & totally optional: skipped when not set (default: null).
  #
  # - <tt>:target3_column</tt>:
  #   column or property name used as to set the value of the tertiary target field;
  #   As above, totally optional: skipped when not set (default: null).
  #
  # - <tt>:payload</tt>:
  #   Array of objects specifying the inline data payload for the search domain.
  #   Each item in the payload Array shall at least respond to:
  #   - <tt>'id'</tt> => unique identifier for the row;
  #   - value of <tt>search_column</tt> as attribute name => main search attribute;
  #   - value of <tt>label_column</tt> as attribute name => main label or description for the row.
  #
  #   Optionally (if used in the setup):
  #   - value of <tt>label2_column</tt> as attribute name => additional label for the row;
  #   - value of <tt>target2_column</tt> as attribute name => field updating the secondary target;
  #   - value of <tt>target3_column</tt> as attribute name => field updating the tertiary target;
  #
  # - <tt>:jwt</tt>:
  #   current_user.jwt (assumes 'current_user' is currently logged-in and valid)
  #
  def initialize(options = {})
    super
    @base_dom_id = options[:base_dom_id] || 'grid-edit'
    @base_api_url = options[:base_api_url]
    @detail_endpoint = options[:detail_endpoint]
    @base_name = options[:base_name]

    @search_endpoint = options[:search_endpoint]
    @search_column = options[:search_column]
    @search2_column = options[:search2_column]
    @search2_dom_id = options[:search2_dom_id]
    @label_column = options[:label_column]
    @label2_column = options[:label2_column]

    @target2_column = options[:target2_column]
    @target3_column = options[:target3_column]
    @target2_field = options[:target2_field]
    @target3_field = options[:target3_field]

    @payload = options[:payload].present? ? options[:payload].to_json : nil
    @jwt = options[:jwt]
  end

  # Skips rendering unless the required parameters are set
  def render?
    @payload.present? || (
      @base_api_url.present? && (@detail_endpoint.present? || @base_name.present?) &&
      @search_endpoint.present? && @jwt.present?
    )
  end

  protected

  # Returns the correct <tt>attribute_name</tt> namespaced using <tt>@base_dom_id</tt>
  # whenever the <tt>@base_dom_id</tt> is not the default value and is not empty.
  def namespaced_attr_name(attribute_name)
    return attribute_name if @base_dom_id == 'grid-edit' || @base_dom_id.blank?

    "#{@base_dom_id}[#{attribute_name}]"
  end
end
