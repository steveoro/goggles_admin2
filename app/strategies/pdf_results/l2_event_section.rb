# frozen_string_literal: true

module PdfResults
  # = PdfResults::L2EventSection
  #
  #   - version:  7-0.7.25
  #   - author:   Steve A.
  #
  # Storage class for the L2-format event section. Header only.
  #
  class L2EventSection
    attr_reader :event_title, :category_code, :gender_code, :relay,
                :additional_fields, :rows

    # Creates a new instance.
    #
    # == Params
    # - <tt>event_title</tt>        => title or name of the event as a String; the style type will be
    #                                  internally "normalized" to a 2-character code.
    #                                  Examples: "50 SL - M25", "100 FA - M25"
    # - <tt>category_code</tt>      => String category code, possibly "normalized" (externally);
    # - <tt>gender_code</tt>        => String gender code;
    # - <tt>categories_cache</tt>   => valid instance reference to a PdfResults::CategoriesCache;
    # - <tt>additional_fields</tt>  => an Hash of additional data fields for this event section, stored "as is";
    #
    def initialize(event_title:, category_code:, gender_code:, categories_cache:, additional_fields: {})
      raise 'Invalid categories cache reference!' unless categories_cache.is_a?(PdfResults::CategoriesCache)

      @event_title = Parser::EventType.normalize_event_title(event_title)
      @relay = L2Converter.event_title_is_a_relay?(@event_title)
      @categories_cache = categories_cache
      @category_code = @categories_cache.normalize_category_code(category_code, relay: @relay)
      @gender_code = gender_code.to_s.upcase
      @additional_fields = additional_fields
      @rows = []
    end
    #-- -----------------------------------------------------------------------
    #++

    # Compares the 2 team names and returns +true+ if they are "almost equal", meaning they are
    # the same, except one is a truncated version of the longer one with a maximum of 8 characters
    # difference in length.
    # Used to match team names whenever they are possibly truncated among different event sections.
    # (E.g.: "SUPADUP Space Pool & Fit" vs. "SUPADUP Space Pool & Fitness ssd")
    #
    # Both parameters must be strings.
    def self.team_names_are_almost_equal(team_name1, team_name2)
      shorter_name = team_name1.length <= team_name2.length ? team_name1.upcase : team_name2.upcase
      longer_name = team_name1.length > team_name2.length ? team_name1.upcase : team_name2.upcase

      longer_name.starts_with?(shorter_name) && (longer_name.length - shorter_name.length) < 9
    end
    #-- -----------------------------------------------------------------------
    #++

    # Instance key comparison.
    # Compares this EventSection with another given one.
    #
    # == Returns
    # +true+ when the two EventSection instances have the same values for
    # their internal fields; +false+ otherwise.
    def ==(other)
      return false unless other.is_a?(PdfResults::L2EventSection)

      @event_title == other.event_title && @category_code == other.category_code &&
        @gender_code == other.gender_code
    end

    # Instance key difference.
    # Compares for difference this EventSection with another given one.
    #
    # == Returns
    # +true+ when the two EventSection instances have different values for their internal fields; +false+ otherwise.
    def !=(other)
      !(self == other) # rubocop:disable Style/InverseMethods
    end

    # Detector for "incomplete" event sections.
    #
    # == Returns
    # +true+ when all the key fields are present; +false+ otherwise.
    def complete?
      @event_title.present? && @category_code.present? && @gender_code.present?
    end
    #-- -----------------------------------------------------------------------
    #++

    # Loops on the internal array of <tt>@rows</tt> and adds <tt>fields_hash</tt> to it
    # if it's totally missing or merges it when some matching key fields are found.
    #
    # Key fields for the merge of a result row are: 'name', 'team', 'timing' & 'relay'.
    # (These works perfectly for both MIRs and MRRs.)
    #
    # == Params:
    # - <tt>fields_hash</tt>: a single result fields Hash containing both the keys to identify the row
    #   to be added (or merged) into the existing array of rows and obviously its values.
    #   This hash must have at least the 'team' key to be considered.
    #
    # === Note:
    # 1. Prevents duplicates in array due to careless usage of '<<'.
    # 2. Since objects like an Hash are referenced in an array, updating directly the object instance
    #    or a reference to it will make the referenced link inside the array be up to date as well.
    #
    # == Returns:
    # +nil+ on no-op, the updated @rows array otherwise (either with an added item or with
    # the field_hash merged into an existing row).
    #
    def add_or_merge_results_in_rows(fields_hash) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      return if !fields_hash.is_a?(Hash) || !fields_hash.key?('team')

      existing_row_merged = false
      @rows.each do |existing_row|
        # ASSUMES: *all* the fields listed in the check below are either present or missing in both rows
        # (compare all key-source fields vs key-dest fields in all existing rows)
        next unless PdfResults::L2EventSection.team_names_are_almost_equal(existing_row['team'].to_s, fields_hash['team'].to_s) &&
                    existing_row['timing'] == fields_hash['timing'] &&
                    existing_row['relay'] == fields_hash['relay'] &&
                    existing_row['name'].to_s.upcase == fields_hash['name'].to_s.upcase &&
                    existing_row['disqualify_type'].to_s.upcase == fields_hash['disqualify_type'].to_s.upcase

        # Don't overwrite computed overall age if the new result hash doesn't have it:
        fields_hash['overall_age'] = existing_row['overall_age'] if existing_row.key?('overall_age') && existing_row['overall_age'].to_i.positive?
        # Update existing row with any missing fields from current result row:
        existing_row.merge!(fields_hash)
        existing_row_merged = true
        break
      end

      # Add the new row unless it was already merged:
      @rows << fields_hash unless existing_row_merged
      @rows
    end
    #-- -----------------------------------------------------------------------
    #++

    # Converts this EventSection instance to an Hash in the "flattened" L2 format.
    # Includes the empty "rows" array for storing result rows and the keys and values from
    # the <tt>additional_fields</tt> Hash, stored "as is" at the same root level of the returned Hash.
    #
    # == Returns
    # An hash filled with the values of the internal fields assigned to their corresponding
    # "L2" keys.
    def to_l2_hash
      {
        'title' => @event_title,
        # Unused:
        # 'fin_id_evento' => nil,
        # 'fin_codice_gara' => nil,
        'fin_sigla_categoria' => @category_code,
        'fin_sesso' => @gender_code,
        'rows' => @rows
      }.merge(@additional_fields)
    end
    #-- -----------------------------------------------------------------------
    #++

    # Debug helper: converts this EventSection instance to a String.
    def to_s
      "[#{self.class}] title: '#{@event_title}', category: '#{@category_code}', gender: '#{@gender_code}', rows tot: #{@rows.count} additional fields: #{@additional_fields.keys}"
    end
  end
end
