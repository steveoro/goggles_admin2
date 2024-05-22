# frozen_string_literal: true

module PdfResults
  # = PdfResults::ContextDAO
  #
  #   - version:  7-0.7.10
  #   - author:   Steve A.
  #
  #
  # Wraps a subset of contextual data extracted from PDF/TXT parsing
  # into a hierarchy-capable object.
  #
  # ContextDAOs:
  # - can store #rows of sibling ContextDAOs, if the source ContextDef acts as a parent for them;
  #   (adding rows is not done internally: add_row(sibling_dao) needs to be called explicitly)
  #
  # - have a #field_hash, which is the flat Hash map of all field names & values collected
  #   from the source ContextDef (which, in turn, treats all its fields & rows as same-level data)
  #
  # == In depth:
  #
  # While ContextDef store the format definition which is used to parse context sections
  # of text and can divide each same section of text in multiple sibling rows of sub-contexts,
  # ContextDAO store all data collected from the specified source ContextDef as same-level
  # fields and values.
  #
  # At the same time, nesting data is possible within ContextDAO if the source ContextDef
  # acts as parent context for other siblings, in which case using #add_row(context_dao)
  # you can add multiple data rows associated to the same parent DAO.
  #
  # As a practical example, assuming we have a hierarchy of 3 nested ContextDefs like these:...
  #
  #   (root) 'event' ---[1:N]---> 'category' ---[1:N]---> 'result' (leaf)
  #                           (#rows of 'event')     (#rows of 'category')
  #
  # ...A single ContextDef('event') can store all associated 'categories' inside its
  # #rows member, with each item storing a list of 'results' for each possible 'category'.
  #
  # This way, by scanning a list of root-level DAO objects we can reconstruct the whole data
  # hierarchy in a single pass.
  #
  # === NOTE:
  # Do not confuse layout format hierarchy (from ContextDef field groups and sub-area sections)
  # with actual data hierarchy (basically given by ContextDef 'parent' property).
  #
  # Any data extracted from a single ContextDef will be treated as coming from a single level
  # of depth in the data hierarchy, regardless of how many rows the ContextDef spans.
  # (All of its fields will become same-level keys in the resulting #data_hash).
  #
  class ContextDAO
    # Properties from source ContextDef
    attr_reader :name, :parent, :key

    # Array of sibling ContextDAOs, added with #add_row(context_dao)
    attr_reader :rows

    # Hash of all fields (names, together with their associated value) collected from the
    # source ContextDef.
    #
    # Fields will be retrieved directly from the parent context inside:
    # - actual fields definitions;
    # - any nested field definition found in any sub-context rows.
    #
    # Note that same-named fields stored under different rows will overwrite each other.
    attr_reader :fields_hash

    # Creates a new context DAO, wrapping all data extracted from a single run
    # of ContextDef#extract(<buffer>, <scan_index>).
    #
    # == Params:
    # - +context+ => direct link to source ContextDef instance; +nil+ (default) for a top-level DAO only.
    #                Top-level DAOs won't have a key and will all be named 'root' and all root-level ContextDefs
    #                will yield DAOs stored as #rows.
    #
    def initialize(context = nil) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      raise 'Invalid ContextDef specified!' unless context.is_a?(ContextDef) || context.nil?

      @name = context&.name || 'root'
      # Store curr. reference to the latest Ctx parent DAO for usage in find & merge:
      @parent = context&.parent&.dao
      @key = context&.key # Use current Context key as UID
      @rows = []

      # Collect all fields from any root-level field group and from sub-area context rows
      # (using the sub-context DAOs #fields_hash directly):
      @fields_hash = {}
      if context&.fields.present?
        context.fields.each { |fd| @fields_hash.merge!({ fd.name => fd.value }) if fd.is_a?(FieldDef) }
      end
      return if context&.rows.blank?

      # Include only data from rows which name is included in the ContextDef data_hash keys:
      context.rows.each do |ctx|
        @fields_hash.merge!(ctx.dao.fields_hash) if ctx.is_a?(ContextDef) && context.data_hash.key?(ctx.name) && ctx.dao.present?
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    # Collects the whole sub-hierarchy data Hash associated with this instance
    # considering any sibling DAOs stored in #rows.
    # Returns the Hash having as elements the values for :name, :key and :rows.
    def data
      result = {
        name: @name,
        key: @key,
        fields: @fields_hash,
        rows: []
      }

      @rows.each do |row|
        next unless row.is_a?(ContextDAO)

        result[:rows] << row.data
      end
      result
    end
    #-- -----------------------------------------------------------------------
    #++

    # Searches recursively for the specified DAO inside the hierarchy, starting at
    # this instance as a descending node, to verify if the specified DAO is really
    # already stored in this subtree or not. (In which case, usually, it needs to be added.)
    #
    # Returns only the DAO with the matching +name+ & +key+.
    # Returns +nil+ otherwise.
    def find_existing(source_dao)
      return nil unless source_dao.is_a?(ContextDAO)
      return self if source_dao.name == name && source_dao.key == key

      # Find DAO in siblings (FIFO, go deeper):
      @rows.find { |dao| dao.find_existing(source_dao) }
    end
    #-- -----------------------------------------------------------------------
    #++

    # Adds unconditionally the specified ContextDAO to this instance @rows array.
    def add_row(sibling_dao)
      raise 'Invalid ContextDAO specified!' unless sibling_dao.is_a?(ContextDAO)

      @rows << sibling_dao
    end
    #-- -----------------------------------------------------------------------
    #++

    # Merges the given ContextDAO into the proper parent DAO belonging to this subtree
    # assuming the parent is either self or a sibling of self.
    #
    # The method searches recursively for the parent name and key,
    # then adds (or merges recursively, if already existing) the specified +dao+
    # as a sibling into its referenced parent.
    #
    # If the parent referenced by +source_dao+ is not found inside
    # the DAO hierarchy starting at this instance (going deeper with the
    # subtree), an error is raised.
    #
    # === Note:
    # To prevent exceptions, merges should be performed only on a root DAO
    # when all zero-depth level DAOs have already been found.
    #
    # If the exception persist during runs, this usually signals that
    # the format definitions used to create the ContextDefs from which
    # the DAOs are extracted may contain logical errors, such as a parent
    # context definition written after its siblings' reference.
    #
    # (Parent context sections should always be defined before their siblings.)
    #
    # === Note on structure merge:
    # Each DAO can store a different data hierarchy subtree. This merge
    # aims at merging two different data subtrees into the same parent node.
    #
    # Given that if two DAOs have the same name & key are considered equals in value,
    # "merging" actually implies adding just the sub-rows from the source to
    # the destination node, preserving the existing ones while adding only what
    # is really missing from the destination DAO.
    #
    # The only exception to the above rule is for headers: given that PDFs are assumed to
    # refer to a single Meeting and the header should contain a key referencing to a single
    # meeting, BUT, sometimes key data like the 'meeting_place' or the 'meeting_date' is
    # not rendered on *all* pages in some of the formats (like 'goswim', for one),
    # to prevent duplicated headers due to slighlty different DAO keys, a special check
    # will be performed if the merging source_dao is named 'header' and its already
    # contained inside the children rows. In this case, the 2 slightly-different 'headers'
    # will have the fields and row merged into one (overlapping any existing values).
    #
    # == Practical use case:
    # - (1:N) events --> (1:N) category x event --> (1:N) results x category
    # - Event or category change/reset on each page;
    # - DAOs collected on a per-page basis, w/ parent section (DAO nodes) repeating on each page
    #   --> AIM: single DAO tree => requires a merge of DAO subtrees
    #
    def merge(source_dao) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/AbcSize
      raise 'Invalid ContextDAO specified!' unless source_dao.is_a?(ContextDAO)

      # Find a destination container for the source DAO: it must have the same name & key
      # as the parent referenced by the source itself.
      dest_parent = self if name == 'root' && source_dao.parent.blank?
      dest_parent ||= find_existing(source_dao.parent) || source_dao.parent
      raise 'Unable to find destination parent for source ContextDAO during merge!' unless dest_parent.is_a?(ContextDAO)

      # See if the source DAO is already inside the destination rows; add it if missing
      # Special cases:
      # 1. 'header': all header DAOs should be merged into one
      # 2. 'post_header': all post-header DAO should be merged into a 'header'
      if source_dao.name == 'header' || source_dao.name == 'post_header'
        header = dest_parent.rows.find { |dao| dao.name == 'header' }
        # Merge any other header (different in key) or post_header into the first child found in destination:
        if header.is_a?(ContextDAO) && header.key != source_dao.key
          # Merge hash fields and each sibling rows into the existing header:
          header.fields_hash.merge!(source_dao.fields_hash)
          source_dao.rows.each { |row_dao| header.add_row(row_dao) }
          return
        end
      end

      existing_dao = dest_parent.rows.find { |dao| dao.name == source_dao.name && dao.key == source_dao.key }

      # Found source DAO as existing? Try to merge it deeper, row by row:
      if existing_dao.is_a?(ContextDAO)
        source_dao.rows.each { |row_dao| existing_dao.merge(row_dao) }
      else # Not included? => add it "as is":
        dest_parent.add_row(source_dao)
      end

      # *Algorithm:*
      # A) Find SELF from dest_parent
      # B) if self not found => add to dest_parent @rows
      # C) if self => check for missing rows & merge iteratively:
      #    PSEUDO: found_dao.rows.each { |subdao| subdao compare if missing or not // MERGE }
    end
    #-- -----------------------------------------------------------------------
    #++

    # Debug helper.
    # Converts DAO contents to a viewable multi-line string representation.
    def to_s
      result = Kernel.format("[%s DAO] key: '%s' {\r\n", @name, @key)
      @fields_hash.each { |key, val| result << "\t'#{key}' => '#{val}'\r\n" }
      if @rows.present?
        result << "\trows: #{@rows.count}\r\n"
        @rows.each do |row_ctx|
          next unless row_ctx.is_a?(ContextDAO)

          result << "\t\t<#{row_ctx.name}>: #{row_ctx.key.truncate(80)}\r\n"
          if row_ctx.rows.present?
            row_ctx.rows.each { |sub_ctx| result << "\t\t\t<#{sub_ctx.name}>: #{sub_ctx.key}\r\n" }
            result << "\t\t\ttot sub-rows = #{row_ctx.rows.count}\r\n"
          end
        end
      end
      result << "}\r\n"
      result
    end

    # Debug helper.
    # Similarly to ContextDef#hierarchy_to_s(), this scans the current #data() structure
    # preparing a (sub-)hierarchy printable string tree, using this DAO as the starting point
    # of the hierarchy, going deeper in breadth-first mode.
    #
    # Returns a printable ASCII (string) tree of this DAO data hierarchy.
    def hierarchy_to_s(dao: self, output: '', depth: 0) # rubocop:disable Metrics/AbcSize
      output = if output.blank? && depth.zero?
                 "\r\n(#{dao.parent.present? ? dao.parent.name : '---'})\r\n"
               else
                 ('  ' * depth) << output
               end
      output << ('  ' * (depth + 1)) <<
        "+-- #{dao.name}#{dao.fields_hash.present? ? '🔸' : ''}\r\n"

      if dao.rows.present?
        output << ('  ' * (depth + 2)) << "  [:rows]\r\n"
        dao.rows.each do |sub_dao|
          output = hierarchy_to_s(dao: sub_dao, output:, depth: depth + 3)
        end
      end

      output
    end
  end
end
