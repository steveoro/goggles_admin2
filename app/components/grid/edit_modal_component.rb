# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.40
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::EditModalComponent
  #
  # Renders an hidden empty modal form, linked to a specific controller name.
  #
  # The title and the attributes displayed in the form can be easily set by
  # binding the show/edit/create buttons for the form to a 'grid-edit' Stimulus JS controller instance.
  #
  # In this way, the form will act as a shared container for the actions invoked by the buttons, and each
  # button will be associated to its own Stimulus controller instance, with a dedicated payload depending
  # on the setup of the button.
  #
  # The resulting action for the form POST created by this component has the following "placeholder":
  # <tt>url_for(only_path: true, controller: @controller_name, action: :update, id: 0)</tt>
  #
  # The row ID must remain zero for new records, and will be replaced by the actual ID of the record by
  # the setup of the buttons using the 'grid-edit' controller.
  #
  # (@see app/javascript/controllers/grid_edit_controller.js)
  #
  # rubocop:disable Metrics/ClassLength
  class EditModalComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>controller_name</tt>: Rails controller name linked to this modal form
    #
    # - <tt>asset_row</tt>:
    #  valid ActiveRecord Model instance to which this component will be linked to (*required*).
    #
    # - <tt>jwt</tt>: required session JWT for API auth (can be left to nil when using static values).
    #
    # - <tt>base_dom_id</tt>: defines the base string name for the DOM ID used by the modal container,
    #   its input form (<tt>"frm-<BASE_MODAL_DOM_ID>"</tt>), its title label (<tt>"<BASE_MODAL_DOM_ID>-modal-title"</tt>)
    #   and its own POST button (<tt>"btn-<BASE_MODAL_DOM_ID>-submit-save"</tt>); defaults to "grid-edit".
    #
    def initialize(controller_name:, asset_row:, api_url: nil, jwt: nil, base_dom_id: 'grid-edit')
      super
      @controller_name = controller_name
      @asset_row = asset_row
      @jwt = jwt
      @base_dom_id = base_dom_id
    end

    # Skips rendering unless the required parameters are set
    def render?
      @controller_name.present? && @asset_row.present? && @base_dom_id.present?
    end
    #-- -----------------------------------------------------------------------
    #++

    protected

    # Returns the base API URL for all endpoints
    def base_api_url
      "#{GogglesDb::AppParameter.config.settings(:framework_urls).api}/api/v3"
    end

    # Returns the correct <tt>attribute_name</tt> namespaced using <tt>@base_dom_id</tt>
    # whenever the <tt>@base_dom_id</tt> is not the default value and is not empty.
    def namespaced_attr_name(attribute_name)
      return attribute_name if @base_dom_id == 'grid-edit' || @base_dom_id.blank?

      "#{@base_dom_id}[#{attribute_name}]"
    end

    # *************************************************************
    # TODO: REFACTOR ALL THE FOLLOWING INTO goggles_db / decorators
    # *************************************************************

    # Assuming the <tt>attribute_name</tt> is an association name ending with "_id", this
    # returns the base entity name ('user_id' => 'user').
    # Needed only if <tt>detail_endpoint_name()</tt> is nil. Returns +nil+ in any other case.
    def base_entity_name(attribute_name)
      return nil unless attribute_name.ends_with?('_id')

      if attribute_name == 'associated_user_id'
        'user'
      else
        attribute_name.to_s.split('_id').first
      end
    end

    # With the same premise as <tt>base_entity_name()</tt>, this returns
    # the associated base endpoint name ('user_id' => 'user').
    # Returns +nil+ otherwise.
    def detail_endpoint_name(attribute_name)
      return nil unless attribute_name.ends_with?('_id')

      if attribute_name == 'associated_user_id'
        'user'
      elsif lookup_entity?(attribute_name)
        # (lookup entities do not have a detail endpoint)
        nil
      else
        attribute_name.to_s.split('_id').first
      end
    end

    # With the same premise as <tt>base_entity_name()</tt>, this returns the endpoint name used for
    # the "search" function; defaults to the pluralization of the base name. Returns +nil+ otherwise.
    def search_endpoint_name(attribute_name)
      return nil unless attribute_name.ends_with?('_id')

      if attribute_name == 'associated_user_id'
        'users'
      elsif lookup_entity?(attribute_name)
        "lookup/#{attribute_name.to_s.split('_id').first}".pluralize
      else
        detail_endpoint_name(attribute_name).pluralize
      end
    end

    # Returns +true+ if the specified <tt>attribute_name</tt> is indeed an association to a supported lookup entity,
    # or returns +false+ otherwise.
    def lookup_entity?(attribute_name)
      %w[
        coach_level_type_id day_part_type_id disqualification_code_type_id edition_type_id
        entry_time_type_id event_types_id gender_type_id hair_dryer_type_id heat_type_id
        locker_cabinet_type_id medal_type_id pool_type_id record_type_id shower_type_id
        stroke_type_id swimmer_level_type_id timing_type_id
      ].include?(attribute_name.to_s)
    end

    # With the same premise as <tt>base_entity_name()</tt>, this returns the column name used for
    # the "search" function; defaults to 'name'. Returns +nil+ otherwise.
    def search_column_name(attribute_name)
      return nil unless attribute_name.ends_with?('_id')
      return 'long_label' if lookup_entity?(attribute_name)

      case attribute_name
      when 'badge_id'
        'short_label'
      when 'category_type_id', 'season_type_id'
        'code'
      when 'meeting_id'
        'description'
      when 'season_id'
        'header_year'
      when 'swimmer_id'
        'complete_name'
      else
        'name'
      end
    end

    # Same as <tt>search_column_name()</tt> but affecting the secondary filtering column for the
    # 'list' endpoint returned by <tt>search_endpoint_name</tt> (if a secondary filtering parameter can be defined).
    # This secondary filtering column acts as an additional "skimmering" parameter for the standard 'list' endpoint.
    # Defaults to +nil+.
    #
    # Typical example: 'category_type_id' additionally filtered by 'season_id'.
    #
    def search2_column_name(attribute_name)
      return nil unless attribute_name.ends_with?('_id')

      case attribute_name
      when 'badge_id', 'category_type_id', 'meeting_id', 'team_affiliation_id'
        'season_id'
      end
    end

    # Returns the node DOM ID that should hold the runtime value for the secondary filtering column.
    # Defaults to +nil+.
    #
    # Typical example: 'category_type_id' => 'season_id' (unless the hidden input is namespaced).
    #
    def search2_dom_id(attribute_name)
      search2_column = search2_column_name(attribute_name)
      return nil if search2_column.blank?

      namespaced_attr_name(search2_column)
    end

    # With the same premise as <tt>base_entity_name()</tt>, this returns the column name used for
    # the "label #1" function; defaults to 'description'. Returns +nil+ otherwise.
    # rubocop:disable Metrics/CyclomaticComplexity
    def label_column_name(attribute_name)
      return nil unless attribute_name.ends_with?('_id')
      return 'label' if lookup_entity?(attribute_name)

      case attribute_name
      when 'badge_id'
        'team_affiliation_id'
      when 'category_type_id', 'season_type_id'
        'short_name'
      when 'city_id'
        'area'
      when 'meeting_id'
        'code'
      when 'season_id'
        'description'
      when 'swimmer_id'
        'year_of_birth'
      when 'swimming_pool_id'
        'nick_name'
      when 'team_id'
        'city_id'
      when 'team_affiliation_id'
        'team_id'
      when 'user_id', 'associated_user_id'
        'email'
      else
        'short_label'
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity

    # With the same premise as <tt>base_entity_name()</tt>, this returns the column name used for
    # the "label #2" function. Defaults & returns +nil+ otherwise.
    # rubocop:disable Metrics/CyclomaticComplexity
    def label2_column_name(attribute_name)
      return nil unless attribute_name.ends_with?('_id')
      return 'code' if lookup_entity?(attribute_name)

      case attribute_name
      when 'badge_id'
        nil
      when 'category_type_id', 'team_affiliation_id'
        'season_id'
      when 'city_id'
        'country'
      when 'meeting_id'
        'header_year'
      when 'season_id'
        'begin_date'
      when 'season_type_id'
        'federation_type_id'
      when 'swimmer_id'
        'gender_type_id'
      when 'swimming_pool_id'
        'pool_type_id'
      when 'team_id'
        'editable_name'
      when 'user_id'
        'description'
      else
        'short_label'
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity
    #-- -----------------------------------------------------------------------
    #++
  end
  # rubocop:enable Metrics/ClassLength
end
