# frozen_string_literal: true

module PdfResults
  # = PdfResults::BaseDef
  #
  #   - version:  7-0.6.00
  #   - author:   Steve A.
  #
  # Base class wrapping common functionalities between FieldDefs & ContextDef.
  #
  class BaseDef
    attr_reader :last_source_before_format # bufferized source from last run
    attr_reader :last_validation_result    # bufferized response from last run

    # Shared initialization for FieldDefs & ContextDef.
    # Requires the #all_props helper method to be defined/overridden in siblings.
    #
    # == Required properties:
    # - +name+ => name of this BaseDef
    #
    def initialize(properties = {})
      raise "Missing required 'name' for #{self.class.name}!" unless properties.stringify_keys.key?('name')

      init_supported_properties
      properties.stringify_keys.each do |key, value|
        # Set only supported properties as member variables:
        var_name = "@#{key}".to_sym
        instance_variable_set(var_name, value) if all_props.include?(key.to_s)

        # ContextDef#rows: store each array item as a sub-context with a parent:
        if key == 'rows' && rows.present?
          rows.each_with_index do |prop_hash, idx|
            rows[idx] = ContextDef.new(
              prop_hash.merge(
                # Make sure name gets a default only if not set:
                name: prop_hash['name'] || "#{properties.stringify_keys['name']}-row#{idx}",
                parent: self
              )
            ) if prop_hash.is_a?(Hash)
          end
        # ContextDef#fields: store each array item as a group of fields:
        elsif key == 'fields' && fields.present?
          fields.each_with_index do |prop_hash, idx|
            fields[idx] = FieldDef.new(prop_hash.merge(parent: self)) if prop_hash.is_a?(Hash)
          end
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    # Applies <tt>curr_lambda</tt> to <tt>src_buffer</tt>, returning the resulting object
    # (which could be either an array or a string).
    #
    # If the source buffer is an array and the lambda is callable on any of its items, it will
    # be applied where possible and the resulting collection returned.
    #
    # Returns the <tt>src_buffer</tt> as is if <tt>curr_lambda</tt> is not callable as a method
    # on <tt>src_buffer</tt> (or on any of its items if it's an array).
    def apply_lambda(curr_lambda, src_buffer)
      return src_buffer if curr_lambda.blank? # bail out for blank lambdas
      return src_buffer.method(curr_lambda).call if src_buffer.respond_to?(curr_lambda) # apply "plain" lambdas
      return src_buffer unless src_buffer.respond_to?(:each) # bail out unless list of lambdas

      src_buffer.map { |token| token.method(curr_lambda).call if token.respond_to?(curr_lambda) }
    end

    # Applies <tt>format</tt> to <tt>src_buffer</tt>, returning the resulting string object.
    #
    # If the source buffer is an array, the first item that satisfies the format is used as new
    # instance value.
    #
    # Returns the <tt>src_buffer</tt> as is if <tt>format</tt> is not applicable on <tt>src_buffer</tt>
    # (or on any of its items if it's an array).
    def apply_format(src_buffer)
      return src_buffer if format.blank? # bail out for blank formats

      # Apply format directly on plain strings:
      return apply_single_regexp(format, src_buffer) if src_buffer.respond_to?(:match)
      return src_buffer unless src_buffer.respond_to?(:each)

      # FIFO token matching format:
      result = nil
      src_buffer.each do |token|
        result = apply_single_regexp(format, token)
        break if result
      end
      result.present? ? result : src_buffer
    end

    # Applies +regexp+ to +str_token+ or returns +nil+ otherwise.
    # If +regexp+ contains a capture expression, the resulting array of captures will be first compacted
    # (to remove any nil captures) and the first non-empty capture will be returned.
    # If +regexp+ does not contain a capture expression, match index is used to extract the substring value.
    def apply_single_regexp(regexp, str_token)
      return unless regexp.is_a?(Regexp) && str_token.present?

      match_idx = str_token =~ regexp
      return unless match_idx

      matches = regexp.match(str_token)
      matches.is_a?(MatchData) && matches.captures.compact.present? ? matches.captures.compact.first : str_token[match_idx..]
    end
    #-- -----------------------------------------------------------------------
    #++

    protected

    # Initializer for all supported property variables.
    # Requires the #all_props() helper method to be defined or overridden in siblings.
    def init_supported_properties
      all_props.each do |prop_key|
        # Store property value in dedicated instance variable:
        instance_variable_set("@#{prop_key}".to_sym, nil)
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
