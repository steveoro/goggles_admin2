# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.39
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
  class EditModalComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>controller_name</tt>: Rails controller name linked to this modal form
    #
    # - <tt>asset_row</tt>:
    #  valid ActiveRecord Model instance to which this component will be linked to (*required*)
    #
    # - <tt>jwt</tt>: required session JWT for API auth. (can be left to nil when using static values)
    def initialize(controller_name:, asset_row:, api_url: nil, jwt: nil)
      super
      @controller_name = controller_name
      @asset_row = asset_row
      @jwt = jwt
    end

    # Skips rendering unless the required parameters are set
    def render?
      @controller_name.present? && @asset_row.present?
    end
    #-- -----------------------------------------------------------------------
    #++

    protected

    # *************************************************************
    # TODO: REFACTOR ALL THE FOLLOWING INTO goggles_db / decorators
    # *************************************************************

    # Returns the base API URL for all endpoints
    def base_api_url
      "#{GogglesDb::AppParameter.config.settings(:framework_urls).api}/api/v3"
    end

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
      when 'category_type_id', 'season_type_id'
        'code'
      when 'season_id'
        'description'
      when 'swimmer_id'
        'complete_name'
      else
        'name'
      end
    end

    # With the same premise as <tt>base_entity_name()</tt>, this returns the column name used for
    # the "label #1" function; defaults to 'description'. Returns +nil+ otherwise.
    # rubocop:disable Metrics/CyclomaticComplexity
    def label_column_name(attribute_name)
      return nil unless attribute_name.ends_with?('_id')
      return 'label' if lookup_entity?(attribute_name)

      case attribute_name
      when 'category_type_id', 'season_type_id'
        'short_name'
      when 'city_id'
        'area'
      when 'season_id'
        'header_year'
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
        'description'
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
      when 'category_type_id', 'team_affiliation_id'
        'season_id'
      when 'city_id'
        'country'
      when 'season_id'
        'begin_date'
      when 'season_type_id'
        'federation_type_id'
      when 'swimmer_id'
        'gender_type_id'
      when 'swimming_pool_id'
        'pool_type_id'
      when 'team_id'
        'name_variations'
      else
        'description'
      end
    end
    # rubocop:enable Metrics/CyclomaticComplexity
    #-- -----------------------------------------------------------------------
    #++
  end
end
