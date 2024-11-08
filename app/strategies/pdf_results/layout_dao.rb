# frozen_string_literal: true

module PdfResults
  # = PdfResults::LayoutDAO
  #
  #   - version:  7-0.7.24
  #   - author:   Steve A.
  #
  # Stores the data extracted from a single data page using the LayoutDef specified in the constructor.
  #
  class LayoutDAO
    # Format name as read from the YAML definition file
    attr_reader :name

    # Creates a new LayoutDAO, wrapping all data extracted from the currently processed document page.
    #
    # == Params:
    # - <tt>layout_def</tt> => the LayoutDef instance used to extract the page ContextDAOs.
    #
    def initialize(layout_def)
      raise 'Invalid LayoutDef specified!' unless layout_def.is_a?(LayoutDef)

      @name = layout_def.name
      @key = layout_def.key

      # @rows = []

      # # Collect all fields from any root-level field group and from sub-area context rows
      # # (using the sub-context DAOs #fields_hash directly):
      # @fields_hash = {}
      # if context&.fields.present?
      #   context.fields.each { |fd| @fields_hash.merge!({ fd.name => fd.value }) if fd.is_a?(FieldDef) }
      # end
      # return if context&.rows.blank?

      # # Include only data from rows which name is included in the ContextDef data_hash keys:
      # context.rows.each do |ctx|
      #   @fields_hash.merge!(ctx.dao.fields_hash) if ctx.is_a?(ContextDef) && context.data_hash.key?(ctx.name) && ctx.dao.present?
      # end
    end
    #-- -----------------------------------------------------------------------
    #++
    #-- -----------------------------------------------------------------------
    #++
  end
end
