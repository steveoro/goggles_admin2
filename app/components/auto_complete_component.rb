# frozen_string_literal: true

#
# = Auto-complete (DB-lookup) component
#
#   - version:  7-0.3.54
#   - author:   Steve A.
#
# Allows a search query on any lookup entity by any field in order to retrieve its ID plus its associated
# details in order to compose and display a full descriptive label and, possibly,
# update also up to other 3 optional target fields.
#
# Uses the Stimulus 'autocomplete_controller.js'.
# As per controller definition, the 4th optional target field can be set only via its DOM ID,
# while the other 3 (including the main target field) just need a specific data target to be set.
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
  # - <tt>base_dom_id</tt>: base target *namespace*; defaults to "grid-edit" (default name disables the namespace for the POST field).
  #   When put inside modal dialog, this should be equal to the base string name used for the DOM ID
  #   used by the modal container; see option <tt>:base_dom_id</tt> of <tt>EditModalComponent</tt>.
  #
  # - <tt>:base_api_url</tt>:
  #  base API URL for data request (w/o endpoint or params)
  #  (*required* only when no payload is given)
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
  #   column or property name used to set the value of the secondary target field;
  #   (totally optional, skipped when not set)
  #
  # - <tt>:target2_class</tt>:
  #   CSS container class override; default: "offset-lg-1 col-lg-5 col-md-10 col-sm-10 my-1"
  #   (good for a pretty large field)
  #
  # - <tt>:target3_field</tt>:
  #   tertiary target field name;
  #   Totally optional: skipped when *both* this and the DOM ID option below are not set
  #   (default: null). This option has precedence over the DOM ID option below.
  #
  # - <tt>:target3_dom_id</tt>:
  #   DOM ID for the 3rd optional target field; skipped when *both* this and the option above are not set (default: null).
  #   The 3rd target field can either be set by its field name (option <tt>:target3_field</tt> above)
  #   or by its DOM ID in case it is rendered outside the parent container node of the component.
  #
  # - <tt>:target3_column</tt>:
  #   column or property name used to set the value of the tertiary target field;
  #   As above, totally optional: skipped when not set (default: null).
  #
  # - <tt>:target3_class</tt>:
  #   CSS container class override; default: "col-lg-1 col-md-2 col-sm-2 my-1"
  #   (good for a very small field)
  #
  # - <tt>:target4_dom_id</tt>:
  #   DOM ID for the 4th optional target field; managed as above & totally optional: skipped when not set (default: null).
  #   This 4th target is referred *only* by its DOM ID instead of its name because it's assumed to be
  #   always placed (and rendered) outside of the current parent node (thus, accessible only via its ID).
  #
  # - <tt>:target4_column</tt>:
  #   column or property name used to set the value of the 4th target field;
  #   As above, totally optional: skipped when not set (default: null).
  #
  # - <tt>:default_value</tt>:
  #   actual default value for the target field (typically '<base_name>_id'); defaults to +nil+
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
    @default_value = options[:default_value] # goes into "<base_name>_id" as default

    @search_endpoint = options[:search_endpoint]
    @search_column = options[:search_column]
    @search2_column = options[:search2_column]
    @search2_dom_id = options[:search2_dom_id]
    @label_column = options[:label_column]
    @label2_column = options[:label2_column]

    @target2_field = options[:target2_field]
    @target2_column = options[:target2_column]
    @target2_class = options[:target2_class] || "offset-lg-1 col-lg-5 col-md-10 col-sm-10 my-1"
    @target3_field = options[:target3_field]
    @target3_dom_id = options[:target3_dom_id]
    @target3_column = options[:target3_column]
    @target3_class = options[:target3_class] || "col-lg-1 col-md-2 col-sm-2 my-1"

    # The following is assumed to be external to the parent node, so no data attribute references are possible:
    @target4_dom_id = options[:target4_dom_id]
    @target4_column = options[:target4_column]

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
