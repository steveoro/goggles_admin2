# frozen_string_literal: true

module PdfResults
  # = PdfResults::ContextDAO
  #
  #   - version:  7-0.7.25
  #   - author:   Steve A.
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
  class ContextDAO # rubocop:disable Metrics/ClassLength
    # Properties from source ContextDef
    attr_reader :name, :key, :parent, :parent_name

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

      @name = context&.alternative_of || context&.name || 'root'
      # Store curr. reference to the latest Ctx parent DAO for usage in find & merge:
      @parent = context&.parent&.dao
      # NOTE: if "parent&.dao" ^^^ here raises an error, then the format definition has referenced a parent which hasn't been defined at all.
      # E.g.:
      # "NoMethodError - undefined method `dao' for "category":String"
      #    => context referenced 'category' as parent without actually defining it elsewhere in the format file. (Most probaly a copy&paste mistake)

      # Store reference to parent name for whenever the parent DAO is not found in the hierarchy.
      # (in this case, the first matching name during merge will be used as destination parent - see #merge)
      #
      # == Typical example:
      # Some layouts may not have a repeated 'header' section on each page and still use different
      # layout format files for each page; in this case, the parent name will continue to reference
      # the 'header' while the @parent link would be nil (as no parent DAO is found during the parsing).
      # During the merge, the first context named 'header' found in the hierarchy will be used as
      # the actual destination parent event though the @parent link is still nil.
      # Without a reference to the parent name, the merge would add any sibling context with a nil
      # parent to the root level, which is NOT what we want (creating orphans).
      @parent_name = context&.parent&.name
      @parent_key = context&.parent&.key
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
    # Returns the Hash having as elements the values for :name, :key and :rows, memoized.
    # (So it's safe to be called multiple times.)
    def collect_data
      return @collect_data if @collect_data.present?

      @collect_data = {
        name: @name,
        key: @key,
        fields: @fields_hash,
        rows: []
      }

      @rows.each do |row|
        next unless row.is_a?(ContextDAO)

        @collect_data[:rows] << row.collect_data
      end
      @collect_data
    end
    #-- -----------------------------------------------------------------------
    #++

    # Compares this instance with the specified DAO to check if they are referring
    # to the same data hierarchy node. This check is performed recursively, by
    # comparing the DAOs' names, keys, and parents and by performing the same
    # check on the parents' DAOs themselves.
    def same_dao?(source_dao)
      return false if source_dao.nil?
      return true if header_or_footer?(source_dao)

      # Whenever the link to the parent is nil due to a parent context not being found in the current data page
      # (as with non-repeated sections that must be carried over implicitly until different in values, like headers
      # or some events), we need to compare both the parent name & key stored inside the instance:
      name == source_dao.name && key == source_dao.key &&
        ((parent == source_dao.parent) || (parent.is_a?(ContextDAO) && parent.same_dao?(source_dao.parent)))
    end

    # Returns +true+ if this instance is either a 'header' or 'footer' and the source_dao is the same.
    # Returns +false+ otherwise.
    def header_or_footer?(source_dao)
      (name.include?('header') && source_dao.name.include?('header')) ||
        (name.include?('footer') && source_dao.name.include?('footer'))
    end

    # Searches recursively for the specified DAO inside the hierarchy, starting at
    # this instance as a descending node, to verify if the specified DAO is really
    # already stored in this subtree or not. (In which case, usually, it needs to be added.)
    #
    # Handles the special case for 'header' and 'footer' sections where the key doesn't
    # matter as they are considered as a single entity (and all merged into one) in the output
    # hierarchy.
    #
    # Returns only the DAO with the matching +name+ & +key+.
    # Returns +nil+ otherwise.
    def find_existing(source_dao)
      return nil unless source_dao.is_a?(ContextDAO)
      return self if same_dao?(source_dao)

      # Find DAO in siblings (FIFO, go deeper):
      @rows.find { |dao| dao.find_existing(source_dao) }
    end

    # Similarly to #find_existing(), this one searches recursively for the specified target name
    # inside the hierarchy, starting at this instance's level and going down the hierarchy.
    # Only the specified name will be matched, no matter the key.
    #
    # Returns the first DAO found with the matching +name+ (including self).
    # Returns +nil+ otherwise.
    def find_existing_by_name_only(target_name)
      return self if target_name == name

      # Find DAO in siblings (FIFO, go deeper):
      @rows.find { |dao| dao.find_existing_by_name_only(target_name) }
    end

    # Searches recursively inside the specified source DAO hierarchy, starting at its parent,
    # and then looking back up the hierarchy, from parent to parent, until a blank parent node is found.
    #
    # Note that "root-like" ancestors should all be merged into the actual "root" DAO at some point.
    # (This delegates to the actual format program inside the .yml file to replicate a correct hierarchy.)
    #
    # Returns possibly an 'header' DAO or any other 'root'-like ancestor for the specified source.
    # Returns +nil+ otherwise.
    def find_root_ancestor(source_dao)
      return nil unless source_dao.is_a?(ContextDAO)
      return source_dao unless source_dao.parent.is_a?(ContextDAO)

      # Look back up if there's a parent set:
      find_root_ancestor(source_dao.parent)
    end
    #-- -----------------------------------------------------------------------
    #++

    # Adds *unconditionally* the specified ContextDAO to this instance @rows array as a new child row.
    #
    # Note that whenever the sibling DAO is not explicitly a _child_ of this instance it's better to use
    # {#merge()} as that method can search and match for the proper starting merge root inside the hierarchy tree.
    def add_row(sibling_dao)
      raise 'Invalid ContextDAO specified!' unless sibling_dao.is_a?(ContextDAO)

      @rows << sibling_dao
    end
    #-- -----------------------------------------------------------------------
    #++

    # Merges the given ContextDAO into the proper parent DAO belonging to this subtree
    # assuming the destination parent is either self or a sibling of self.
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
    #     <self DAO(name, key, parent)> (target / destination)
    #        |
    #        |    <-- merge --|  <source DAO (name, key, parent)>
    #        |                       |
    #     [rows]                     |
    #                              [rows]
    #
    # Part of the merging process requires finding the correct parent for the source DAO
    # and its rows. The parent could be this same DAO instance or any other DAO in its
    # sibling rows.
    #
    # Given that two DAOs are considered equals in value whenever they have the same name & key,
    # "merging" actually implies adding just the sub-rows from the source to
    # the destination node, preserving the existing rows while adding only what
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
    # == Algorithm / pseudo-code:
    # A) Find SELF from dest_parent
    # B) if self not found => add to dest_parent @rows
    # C) if self => check for missing rows & merge iteratively:
    #      found_dao.rows.each { |subdao| subdao compare if missing or not // MERGE }
    #
    def merge(source_dao) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/AbcSize
      raise 'Invalid ContextDAO specified!' unless source_dao.is_a?(ContextDAO)

      # DEBUG ----------------------------------------------------------------
      # binding.pry if source_dao.key.to_s.include?('M 30|00.25.50') && key.blank?
      # ----------------------------------------------------------------------
      # Find a destination container for the source DAO: it must have the same name & key
      # as the parent referenced by the source itself.

      # Merge iteratively into #rows each subtree and return whenever we hit destination level:
      if same_dao?(source_dao)
        source_dao.rows.each { |row_dao| merge(row_dao) }
        return
      end

      # TODO: CHECK if the following check is still needed after the recent refactoring:

      # Special cases - headers & footers, "merge fields into one" regardless of key:
      # 1. 'header' & 'post_header' (all header-type DAOs should be merged into one)
      # 2. 'footer' (same as above, but with different base name)
      if source_dao.name.include?('header') || source_dao.name.include?('footer')
        target_name = source_dao.name.include?('header') ? 'header' : 'footer'
        header = find_existing_by_name_only(target_name)
        # Merge any other header (different in key) or post_header into the first child found in destination:
        if header.is_a?(ContextDAO) && header.key != source_dao.key
          # Merge hash fields and each sibling rows into the existing header:
          header.fields_hash.merge!(source_dao.fields_hash)
          source_dao.rows.each { |row_dao| header.merge(row_dao) }
          return
        end
      end

      # Special case - "root-like" subtrees with only a matching name but parent link missing:
      # (Although, with "standard" format hierarchies only true root-level DAOs should have no parent)
      dest_parent = self if source_dao.parent.blank? && ((name == 'root' && source_dao.parent.blank?) || (name == source_dao.parent_name))

      # Each supplied root DAO (with rows) must have all its row merged into
      # this same DAO as a single array of uniquely-merged rows, so that the hierarchy tree
      # is properly built (with just 1 DAO named 'root').

      # Find source reference to DAO parent in order to have key & structure for matching the tree merging:
      dest_parent ||= source_dao.parent
      # ^^ For pages w/o header, this is a reference to another instance in a possibly different subtree and with nil key.
      # We need to find a correct reference inside this instance's hierarchy tree to actually perform the merge:

      # Find the actual target parent DAO for the merge inside *this* subtree using the parent keys from the instance set above:
      target_dao = find_existing(dest_parent)

      # Special case - both source & current subtrees are sibling at the same level:
      # (can't find the target, as dest_parent is actually higher in the hierarchy on this subtree;
      #  example: both source and self are 'results' and need to be merged into 'category', self's parent)
      if target_dao.nil? && dest_parent.is_a?(ContextDAO) && parent.is_a?(ContextDAO)
        parent.merge(source_dao)
        return
      end

      # Special case - TARGET MISSING @ "root" level
      # (Usually root subtree is missing either an "header" DAO or any other required target DAO)
      # This may happen whenever a page doesn't repeat the header, belongs to the same master context and it is bound to it,
      # and/or is at the final root-merging collection phase of the current data page without the header or any other
      # required parent subtree being already merged into the root.
      if target_dao.nil? && dest_parent.is_a?(ContextDAO) && (name == 'root')
        # => 1. make sure there's an 'header' inside this 'root' (may be stored into the source subtree)
        # => 2. move back the insertion point until we find the missing 'header' (assuming there's one in the source)
        #       so that we can then "graft" it onto the root:
        grafting_dao = find_root_ancestor(dest_parent)
        merge(grafting_dao)
        return
      end

      # NOTE: whenever the following happens, it may be due to a context_def that is optional
      #       (similar to the 'header' special case above) but required anyway in the hierarchy tree.
      #       For ex.: an expected 'rel_category' needed by a 'rel_team' context,
      #                which should probably point as a parent directly to an 'event' instead if the 'rel_category' is
      #                known to be possibly missing.
      # DEBUG ----------------------------------------------------------------
      # binding.pry unless target_dao.is_a?(ContextDAO)
      # ----------------------------------------------------------------------
      raise 'Unable to find destination parent for source ContextDAO during merge!' unless target_dao.is_a?(ContextDAO)

      # Seek recursively for the source DAO inside *this* subtree; add it ONLY if missing:
      existing_dao = find_existing(source_dao)

      # DEBUG ----------------------------------------------------------------
      # puts "\r\n" if source_dao.rows.count.positive?
      # puts "'#{key}' <==[MERGE]==| '#{source_dao.key}'"
      # DEBUG VERBOSE --------------------------------------------------------
      # puts hierarchy_to_s
      # puts "\r\n"

      # Found same source DAO as existing? Try to merge its subtrees deeper, row by row:
      # (Merge will automatically return for any leaf w/o any rows on the #same_dao? check above)
      if existing_dao.is_a?(ContextDAO)
        existing_dao.merge(source_dao) # Merge any possible residual difference between the 2 subtrees
        # DEBUG ----------------------------------------------------------------
        # puts "'#{existing_dao.key}' existing_dao.rows: #{existing_dao.rows.count}" if source_dao.rows.count.positive?
        # DEBUG ----------------------------------------------------------------
      else # Not already existing? => add it "as is" as a child of the parent:
        target_dao.add_row(source_dao)
        # DEBUG ----------------------------------------------------------------
        # puts "'#{target_dao.key}' TARGET_DAO.rows: #{target_dao.rows.count}"
        # DEBUG ----------------------------------------------------------------
      end
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
    def hierarchy_to_s(dao: self, output: '', depth: 0, show_keys: true) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      output = if output.blank? && depth.zero?
                 "\r\n(#{dao.parent.present? ? dao.parent.name : '---'})\r\n"
               else
                 ('  ' * depth) << output
               end
      output << ('  ' * (depth + 1)) << "+-- #{dao.name}"
      output << '🔸' if dao.fields_hash.present?
      output << "  #{dao.key}" if show_keys && dao.key.present?
      output << "\r\n"

      if dao.rows.present?
        output << ('  ' * (depth + 2)) << "  [:rows]\r\n"
        dao.rows.each do |sub_dao|
          output = hierarchy_to_s(dao: sub_dao, output:, depth: depth + 3, show_keys:)
        end
      end

      output
    end
  end
end
