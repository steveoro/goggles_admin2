# frozen_string_literal: true

module Import
  #
  # = Import::Entity
  #
  #   - version:  7-0.3.53
  #   - author:   Steve A.
  #   - build:    20220617
  #
  # Wrapper for actual DB Models built or retrieved by the Import::MacroSolver.
  #
  # For each entity row targeted by the MacroSolver (a single Swimmer row associated to
  # a result that has to be imported, for example) this needs to be:
  # 1. parsed (identified in column values from the source text);
  # 2. built up (from the parsed data, including all the required values and associations);
  # 3. seeked for existance (searched on the DB);
  # 4. persisted (saved to the DB if modified).
  #
  # This class wraps all the required data for the above steps.
  # Specifically, if the "search phase" finds multiple matches, it will store both the best match
  # and the full list of candidates sorted by decreasing score.
  #
  class Entity
    attr_reader :row, :matches, :bindings

    # Creates a new Import::Entity instance.
    #
    # == Params
    # - <tt>:row</tt> => target row (any model instance, best-candidate from possible matches or new target row; *required*)
    #
    # - <tt>:matches</tt> => Array of all matching candidates; default: empty ([])
    #
    # - <tt>:bindings</tt> => Hash of required association bindings, keyed by its string model name
    #                         (i.e.: 'gender_type' => <GenderType instance or reference key to it>);
    #                         default: empty ({})
    #
    # - <tt>:toggle_debug</tt> => when true, additional debug output will be generated (default: +false+)
    #
    def initialize(row:, matches: [], bindings: {}, toggle_debug: false)
      @row = row
      @matches = matches
      @bindings = bindings
      @toggle_debug = toggle_debug
    end
    #-- ------------------------------------------------------------------------
    #++

    # Creates a new Import::Entity assuming the specified <tt>data_hash</tt> includes at least
    # the required <tt>'row'</tt> member.
    #
    # == Params
    # - <tt>data_hash</tt> => the Hash storing the actual entity <tt>'row'</tt>, its possible (optional)
    #   alternative <tt>'matches'</tt> and the sub-hash of optional <tt>bindings</tt> associations,
    #   each one keyed by the association name.
    #
    def self.from_hash(data_hash)
      Entity.new(row: data_hash['row'], matches: data_hash['matches'], bindings: data_hash['bindings'])
    end
    #-- ------------------------------------------------------------------------
    #++

    # Adds the specified <tt>additional_bindings</tt> to the current bindings Hash.
    # Returns the current bindings Hash.
    #
    # == Params
    # - <tt>additional_bindings</tt> => Hash to be merged with the current bindings Hash
    #
    def add_bindings!(additional_bindings)
      @bindings.merge!(additional_bindings)
      @bindings
    end
  end
end
