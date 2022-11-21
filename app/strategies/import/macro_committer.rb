# frozen_string_literal: true

module Import
  #
  # = MacroSolver
  #
  #   - version:  7-0.4.20
  #   - author:   Steve A.
  #   - build:    20221025
  #
  # Given a MacroSolver instance that stores the already-precessed contents of the result JSON data file,
  # this class commits the individual entities "solved", either by creating the missing rows
  # or by updating any row existing and found with changes.
  #
  # The solver's data will be progressively substituted with the updated or created model rows, logging
  # the process in the meantime.
  #
  # Each updated or created row will generate SQL statements appended to the overall result
  # SQL batch log file, with all the statements wrapped into a single transaction. (@see SqlMaker)
  #
  class MacroCommitter
    # Creates a new MacroCommitter instance.
    #
    # == Params
    # - <tt>:solver</tt> => Import::MacroSolver containing the structures of the already-processed JSON result file (*required*)
    #
    def initialize(solver:)
      raise(ArgumentError, 'Invalid Solver type') unless solver.is_a?(Import::MacroSolver)

      solver.data['sections'] = nil # This should reduce memory footprint at least a bit
      @solver = solver
      @season = solver.season
      @data = solver.data || {}
      @sql_log = []
    end
    #-- ------------------------------------------------------------------------
    #++

    attr_reader :sql_log, :solver

    # Returns Import::Solver#data, as specified with the constructor
    # (@see app/strategies/import/macro_solver.rb)
    attr_accessor :data

    #-- ------------------------------------------------------------------------
    #++

    # Compares an already serialized Model row (if it has a valid ID) with its
    # corresponding (allegedly) existing DB row, returning the Hash of attributes
    # that have changed or are different.
    #
    # Safe to call even for new model rows: it returns the "compacted" hash of attributes
    # that can be used for an INSERT statement (skips timestamps and lock_version; row IDs
    # are kept in the output hash so that it can be manually checked by reading subsequent
    # rows in any resulting SQL file).
    #
    # An attribute of the model row will be considered as an appliable change if it
    # is not blank and differs from the value stored in the database.
    # (This method won't overwrite existing DB columns with nulls or blanks)
    #
    # == Params:
    # - <tt>model_row</tt>: the row Model instance to be processed;
    #
    # - <tt>db_row</tt>: the existing DB-stored row corresponding to the Model row instance above;
    #   (default: +nil+ => will try to use the model row ID)
    #
    # == Returns
    # An Hash of changed attributes (column => value), selected from the given
    # model row. If the model row doesn't have an ID, all its attributes will be returned.
    #
    # (In other words, the hash of attributes of <tt>model_row</tt> that can be
    # used for an update of its corresponding database row.)
    #
    def self.difference_with_db(model_row, db_row = nil)
      if model_row.id.blank?
        return model_row.attributes.reject do |col, val|
                 %w[lock_version created_at updated_at].include?(col) || val.nil?
               end
      end

      db_row ||= model_row.class.find_by(id: model_row.id)
      model_row.attributes.reject do |column, value|
        value.blank? ||
          value == db_row&.send(column) ||
          %w[id lock_version created_at updated_at].include?(column)
      end
    end
    #-- ------------------------------------------------------------------------
    #++

    # Wraps all individual entities commit methods into a single SQL transaction.
    # Each invoked commit method updates the solved data reference with the
    # resulting ID (if new) and appends the SQL statement to the internal SQL
    # log file.
    def commit_all
      @sql_log << "-- \"#{@data['name']}\""
      @sql_log << "-- #{@data['dateDay1']}/#{@data['dateMonth1']}/#{@data['dateYear1']}\r\n"
      # NOTE: uncommenting the following may yield nulls for created_at & updated_at if we don't provide values in the row
      @sql_log << 'SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'
      @sql_log << "--\r\n"

      ActiveRecord::Base.transaction do
        commit_meeting
        check_and_commit_calendar
        commit_cities
        commit_pools
        commit_sessions
        commit_teams_and_affiliations
        commit_swimmers_and_badges
        commit_events
        commit_programs
        commit_ind_results

        @sql_log << "\r\n--\r\n"
        @sql_log << 'COMMIT;'
      end
    end
    #-- ------------------------------------------------------------------------
    #++

    # Commits the changes for the 'meeting' entity of the solver.
    #
    # == Returns
    # The newly serialized (either updated or created) Meeting row, also available
    # inside the #data Hash as the value for 'meeting'.
    #
    # Updates:
    # - #data['meeting'] row with the resulting model
    #
    def commit_meeting
      meeting = @solver.cached_instance_of('meeting', nil)
      # Assume all meetings in list are confirmed (even if they can be cancelled later):
      meeting.confirmed = true

      # Override the Import::Entity with the actual row and return it:
      @data['meeting'] = commit_and_log(meeting)
    end
    #-- ------------------------------------------------------------------------
    #++

    # Assuming the "solved" Meeting has been already committed, this checks and possibly
    # updates or creates the corresponding calendar row.
    #
    # == Returns
    # The newly serialized (either updated or created) Calendar row, now also available
    # inside the #data Hash as the value for 'calendar'.
    #
    # Updates:
    # - #data['calendar'] row with the resulting model
    #
    def check_and_commit_calendar
      meeting = @data['meeting']
      raise StandardError, 'Meeting not successfully committed yet!' unless meeting.is_a?(GogglesDb::Meeting) && meeting.valid?

      # (ASSERT: only 1 code per season)
      existing_row = GogglesDb::Calendar.for_season(@season).for_code(meeting.code).first
      model_row = GogglesDb::Calendar.new(
        id: existing_row&.id,
        meeting_id: meeting.id,
        meeting_code: meeting.code,
        scheduled_date: meeting.header_date,
        meeting_name: meeting.description,
        meeting_place: [@data['venue1'], @data['address1']].join(', '),
        season_id: @season.id,
        year: @data['dateYear1'],
        month: @data['dateMonth1'],
        results_link: @data['meetingURL'],
        manifest_link: @data['manifestURL'],
        organization_import_text: @data['organization'],
        cancelled: meeting.cancelled
      )

      @data['calendar'] = commit_and_log(model_row)
    end
    #-- ------------------------------------------------------------------------
    #++

    # Commits the changes for all the 'city' entities of the solver.
    #
    # == Returns
    # The Hash of processed cities where all the keys are pointing
    # to a serialized model row instead of an Import::Entity wrapper.
    #
    # Updates:
    # - #data['city'] Hash, substituting each keyed value with the resulting model
    #
    def commit_cities
      entity_keys = @data['city']&.keys&.compact
      total = entity_keys&.count
      idx = 0

      entity_keys&.each do |entity_key|
        idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', msg: "commit City '#{entity_key}'", progress: idx, total: total)

        model_row = @solver.cached_instance_of('city', entity_key)
        # Override the Import::Entity with the actual row:
        @data['city'][entity_key] = commit_and_log(model_row)
      end

      @data['city']
    end
    #-- ------------------------------------------------------------------------
    #++

    # Commits the changes for all the 'swimming_pool' entities of the solver.
    # Associated bindings must be already committed prior of calling this method.
    #
    # == Returns
    # The Hash of processed swimming pools where all the keys are pointing
    # to a serialized model row instead of an Import::Entity wrapper.
    #
    # Updates:
    # - #data['swimming_pool'] Hash, substituting each keyed value with the resulting model
    #
    def commit_pools
      # Limit pools only to the ones *actually* being used in the bindings & skip and possible initial
      # wrong match with a totally different string key.
      # This happens especially when the meeting is edited from a new one to an existing one, which has
      # a different pre-existing pool (that won't necessarily use the same string key).
      # The old, wrong match is left inside the allocated entities, even if the sessions don't bound
      # to that anymore. (This should be fixed in future versions.)
      # With this filtering, we'll avoid trying to commit duplicated pools due to code names already existing
      # or other integrity violations.
      total_sessions = @data['meeting_session']&.compact&.count
      actual_bound_keys = []
      (0 ... total_sessions).each do |index|
        parent_bindings_hash = @solver.cached_instance_of('meeting_session', 0, 'bindings')
        used_key = parent_bindings_hash&.fetch('swimming_pool', nil)
        actual_bound_keys << used_key if used_key.present? && !actual_bound_keys.include?(used_key)
      end

      entity_keys = @data['swimming_pool']&.keys&.compact.keep_if { |key| actual_bound_keys.include?(key) }
      total = entity_keys&.count
      idx = 0

      entity_keys&.each do |entity_key|
        idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', msg: "commit Sw.Pool '#{entity_key}'", progress: idx, total: total)

        model_row = @solver.cached_instance_of('swimming_pool', entity_key)
        bindings_hash = @solver.cached_instance_of('swimming_pool', entity_key, 'bindings')
        # Make sure all bindings have a valid ID:
        bindings_hash.each do |binding_model_name, binding_key|
          # Update only the single-association bindings in the model_row:
          update_method = "#{binding_model_name}_id="
          next unless model_row.respond_to?(update_method)

          # ASSUMES: binding row has already been committed & logged by previous calls => binding_row.id.positive?
          binding_row = @solver.cached_instance_of(binding_model_name, binding_key)
          model_row.send(update_method, binding_row.id)
        end
        # Override the Import::Entity with the actual row:
        @data['swimming_pool'][entity_key] = commit_and_log(model_row)
      end

      @data['swimming_pool']
    end
    #-- ------------------------------------------------------------------------
    #++

    # Commits the changes for all the 'meeting_session' entities of the solver.
    # Associated bindings must be already committed prior of calling this method.
    #
    # == Returns
    # The Array of processed meeting sessions where all the items stored are
    # a serialized model row instead of an Import::Entity wrapper.
    #
    # Updates:
    # - #data['meeting_session'] Array
    #
    def commit_sessions
      meeting = @data['meeting']
      raise StandardError, 'Meeting not successfully committed yet!' unless meeting.is_a?(GogglesDb::Meeting) && meeting.valid?

      entity_keys = @data['meeting_session']&.compact
      total = entity_keys&.count

      entity_keys&.each_with_index do |_entity_hash, index|
        ActionCable.server.broadcast('ImportStatusChannel', msg: "commit M.Session '#{index + 1}'", progress: index + 1, total: total)

        model_row = @solver.cached_instance_of('meeting_session', index)
        model_row.meeting_id = meeting.id
        bindings_hash = @solver.cached_instance_of('meeting_session', index, 'bindings')
        # Make sure all bindings have a valid ID:
        bindings_hash.each do |binding_model_name, binding_key|
          next if binding_model_name == 'meeting' # (already took care of this with the 1-liner above)

          # Update only the single-association bindings in the model_row:
          update_method = "#{binding_model_name}_id="
          next unless model_row.respond_to?(update_method)

          # ASSUMES: binding row has already been committed & logged by previous calls => binding_row.id.positive?
          binding_row = @solver.cached_instance_of(binding_model_name, binding_key)
          model_row.send(update_method, binding_row.id)
        end
        # Override the Import::Entity with the actual row:
        @data['meeting_session'][index] = commit_and_log(model_row)
      end

      @data['meeting_session']
    end
    #-- ------------------------------------------------------------------------
    #++

    # Commits the changes for all the 'team' entities of the solver,
    # building also the associated 'team_affiliation' in the process.
    #
    # == Returns
    # The Hash of processed teams where all the keys are pointing
    # to a serialized model row instead of an Import::Entity wrapper.
    #
    # Updates:
    # - #data['team'] Hash
    # - #data['team_affiliation'] Hash
    #
    def commit_teams_and_affiliations
      entity_keys = @data['team']&.keys&.compact
      total = entity_keys&.count
      idx = 0
      # Force progress clearing:
      ActionCable.server.broadcast('ImportStatusChannel', msg: 'committing Teams', progress: 1, total: 1)

      entity_keys&.each do |entity_key|
        idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', msg: "commit Team '#{entity_key}'", progress: idx, total: total)

        model_row = @solver.cached_instance_of('team', entity_key)
        bindings_hash = @solver.cached_instance_of('team', entity_key, 'bindings')
        # Make sure all bindings have a valid ID:
        bindings_hash.each do |binding_model_name, binding_key|
          # Update only the single-association bindings in the model_row:
          # (ok for 'team.city' but not for 'team.team_affiliations')
          update_method = "#{binding_model_name}_id="
          next unless model_row.respond_to?(update_method)

          # ASSUMES: binding row has already been committed & logged by previous calls => binding_row.id.positive?
          binding_row = @solver.cached_instance_of(binding_model_name, binding_key)
          model_row.send(update_method, binding_row.id)
        end
        # Force required columns that may have been cleared out during edits:
        model_row.name = model_row.editable_name if model_row.name.blank?
        # Override the Import::Entity with the actual row:
        @data['team'][entity_key] = commit_and_log(model_row)
      end

      commit_affiliations
      @data['team']
    end
    #-- ------------------------------------------------------------------------
    #++

    # Commits the changes for all the 'swimmer' entities of the solver,
    # building also the associated 'badge' in the process.
    #
    # == Returns
    # The Hash of processed swimmers where all the keys are pointing
    # to a serialized model row instead of an Import::Entity wrapper.
    #
    # Updates:
    # - #data['swimmer'] Hash
    # - #data['badge'] Hash
    #
    def commit_swimmers_and_badges
      entity_keys = @data['swimmer']&.keys&.compact
      total = entity_keys&.count
      idx = 0
      # Force progress clearing:
      ActionCable.server.broadcast('ImportStatusChannel', msg: 'committing Swimmers', progress: 1, total: 1)

      entity_keys&.each do |entity_key|
        idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', msg: "commit Swimmer '#{entity_key}'", progress: idx, total: total)

        model_row = @solver.cached_instance_of('swimmer', entity_key)
        bindings_hash = @solver.cached_instance_of('swimmer', entity_key, 'bindings')
        # Make sure all bindings have a valid ID:
        bindings_hash.each do |binding_model_name, binding_key|
          # Update only the single-association bindings in the model_row:
          update_method = "#{binding_model_name}_id="
          next unless model_row.respond_to?(update_method)

          # ASSUMES: binding row has already been committed & logged by previous calls => binding_row.id.positive?
          binding_row = @solver.cached_instance_of(binding_model_name, binding_key)
          model_row.send(update_method, binding_row.id)
        end
        # Override the Import::Entity with the actual row:
        @data['swimmer'][entity_key] = commit_and_log(model_row)
      end

      commit_badges
      @data['swimmer']
    end
    #-- ------------------------------------------------------------------------
    #++

    # Commits the changes for the 'meeting_event' entities of the solver.
    def commit_events
      entity_keys = @data['meeting_event']&.keys&.compact
      total = entity_keys&.count
      idx = 0
      # Force progress clearing:
      ActionCable.server.broadcast('ImportStatusChannel', msg: 'committing M.Events', progress: 1, total: 1)

      entity_keys&.each do |entity_key|
        idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', msg: "commit M.Event '#{entity_key}'", progress: idx, total: total)

        model_row = @solver.cached_instance_of('meeting_event', entity_key)
        bindings_hash = @solver.cached_instance_of('meeting_event', entity_key, 'bindings')
        # Make sure all bindings have a valid ID:
        bindings_hash.each do |binding_model_name, binding_key|
          # Update only the single-association bindings in the model_row:
          update_method = "#{binding_model_name}_id="
          next unless model_row.respond_to?(update_method)

          # ASSUMES: binding row has already been committed & logged by previous calls => binding_row.id.positive?
          binding_row = @solver.cached_instance_of(binding_model_name, binding_key)
          model_row.send(update_method, binding_row.id)
        end
        # Assume all validated bindings have been solved and re-seek for an existing row using an educated clause:
        db_row = GogglesDb::MeetingEvent.where(
          meeting_session_id: model_row.meeting_session_id,
          event_type_id: model_row.event_type_id,
          heat_type_id: model_row.heat_type_id
        ).first
        model_row.id = db_row.id if db_row
        # Override the Import::Entity with the actual row:
        @data['meeting_event'][entity_key] = commit_and_log(model_row)
      end

      @data['meeting_event']
    end
    #-- ------------------------------------------------------------------------
    #++

    # Commits the changes for the 'meeting_program' entities of the solver.
    def commit_programs
      entity_keys = @data['meeting_program']&.keys&.compact
      total = entity_keys&.count
      idx = 0
      # Force progress clearing:
      ActionCable.server.broadcast('ImportStatusChannel', msg: 'committing M.Prgs.', progress: 1, total: 1)

      entity_keys&.each do |entity_key|
        idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', msg: "commit M.Prg. '#{entity_key}'", progress: idx, total: total)

        model_row = @solver.cached_instance_of('meeting_program', entity_key)
        bindings_hash = @solver.cached_instance_of('meeting_program', entity_key, 'bindings')
        # Make sure all bindings have a valid ID:
        bindings_hash.each do |binding_model_name, binding_key|
          # Update only the single-association bindings in the model_row:
          update_method = "#{binding_model_name}_id="
          next unless model_row.respond_to?(update_method)

          # ASSUMES: binding row has already been committed & logged by previous calls => binding_row.id.positive?
          binding_row = @solver.cached_instance_of(binding_model_name, binding_key)
          model_row.send(update_method, binding_row.id)
        end
        # Assume all validated bindings have been solved and re-seek for an existing row using an educated clause:
        db_row = GogglesDb::MeetingProgram.where(
          meeting_event_id: model_row.meeting_event_id,
          category_type_id: model_row.category_type_id,
          gender_type_id: model_row.gender_type_id
        ).first
        model_row.id = db_row.id if db_row
        # Override the Import::Entity with the actual row:
        @data['meeting_program'][entity_key] = commit_and_log(model_row)
      end

      @data['meeting_program']
    end
    #-- ------------------------------------------------------------------------
    #++

    # Commits the changes for the 'meeting_individual_result' entities of the solver.
    def commit_ind_results
      entity_keys = @data['meeting_individual_result']&.keys&.compact
      total = entity_keys&.count
      idx = 0
      # Force progress clearing:
      ActionCable.server.broadcast('ImportStatusChannel', msg: 'committing MIRs', progress: 1, total: 1)

      entity_keys&.each do |entity_key|
        idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', msg: "commit MIR '#{entity_key}'", progress: idx, total: total)

        model_row = @solver.cached_instance_of('meeting_individual_result', entity_key)
        bindings_hash = @solver.cached_instance_of('meeting_individual_result', entity_key, 'bindings')
        # Make sure all bindings have a valid ID:
        bindings_hash.each do |binding_model_name, binding_key|
          # Update only the single-association bindings in the model_row:
          update_method = "#{binding_model_name}_id="
          next unless model_row.respond_to?(update_method)

          # ASSUMES: binding row has already been committed & logged by previous calls => binding_row.id.positive?
          binding_row = @solver.cached_instance_of(binding_model_name, binding_key)
          model_row.send(update_method, binding_row.id)
        end
        # Assume all validated bindings have been solved and re-seek for an existing row using an educated clause:
        db_row = GogglesDb::MeetingIndividualResult.where(
          meeting_program_id: model_row.meeting_program_id,
          team_id: model_row.team_id,
          swimmer_id: model_row.swimmer_id
        ).first
        model_row.id = db_row.id if db_row
        # Override the Import::Entity with the actual row:
        @data['meeting_individual_result'][entity_key] = commit_and_log(model_row)
      end

      @data['meeting_individual_result']
    end
    #-- ------------------------------------------------------------------------
    #++

    # Commits the changes for all the 'team_affiliation' entities of the solver.
    #
    # == Returns
    # The Hash of processed team affiliations where all the keys are pointing
    # to a serialized model row instead of an Import::Entity wrapper.
    #
    # Updates:
    # - #data['team_affiliation'] Hash
    #
    def commit_affiliations
      entity_keys = @data['team_affiliation']&.keys&.compact
      total = entity_keys&.count
      idx = 0
      # Force progress clearing:
      ActionCable.server.broadcast('ImportStatusChannel', msg: 'committing T.Affiliations', progress: 1, total: 1)

      entity_keys&.each do |entity_key|
        idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', msg: "commit T.Aff. '#{entity_key}'", progress: idx, total: total)

        model_row = @solver.cached_instance_of('team_affiliation', entity_key)
        bindings_hash = @solver.cached_instance_of('team_affiliation', entity_key, 'bindings')
        # Make sure all bindings have a valid ID:
        bindings_hash.each do |binding_model_name, binding_key|
          # Update only the single-association bindings in the model_row:
          update_method = "#{binding_model_name}_id="
          next unless model_row.respond_to?(update_method)

          # ASSUMES: binding row has already been committed & logged by previous calls => binding_row.id.positive?
          binding_row = @solver.cached_instance_of(binding_model_name, binding_key)
          model_row.send(update_method, binding_row.id)
        end
        # Assume all bindings have been solved and re-seek for an existing row using an educated where clause
        # and giving precedence to what's been found as already existing:
        db_row = GogglesDb::TeamAffiliation.where(team_id: model_row.team_id, season_id: @season.id).first
        model_row.id = db_row.id if db_row
        # Override the Import::Entity with the actual row:
        @data['team_affiliation'][entity_key] = commit_and_log(model_row)
      end

      @data['team_affiliation']
    end

    # Commits the changes for all the 'badge' entities of the solver.
    #
    # == Returns
    # The Hash of processed team badges where all the keys are pointing
    # to a serialized model row instead of an Import::Entity wrapper.
    #
    # Updates:
    # - #data['badge'] Hash
    #
    def commit_badges
      entity_keys = @data['badge']&.keys&.compact
      total = entity_keys&.count
      idx = 0
      # Force progress clearing:
      ActionCable.server.broadcast('ImportStatusChannel', msg: 'committing Badges', progress: 1, total: 1)

      entity_keys&.each do |entity_key|
        idx += 1
        ActionCable.server.broadcast('ImportStatusChannel', msg: "commit Badge '#{entity_key}'", progress: idx, total: total)

        model_row = @solver.cached_instance_of('badge', entity_key)
        bindings_hash = @solver.cached_instance_of('badge', entity_key, 'bindings')
        # Make sure all bindings have a valid ID:
        bindings_hash.each do |binding_model_name, binding_key|
          # Update only the single-association bindings in the model_row:
          update_method = "#{binding_model_name}_id="
          next unless model_row.respond_to?(update_method)

          # ASSUMES: binding row has already been committed & logged by previous calls => binding_row.id.positive?
          binding_row = @solver.cached_instance_of(binding_model_name, binding_key)
          model_row.send(update_method, binding_row.id)
        end
        # Assume all validated bindings have been solved and re-seek for an existing row using an educated clause:
        db_row = GogglesDb::Badge.where(swimmer_id: model_row.swimmer_id, team_id: model_row.team_id, season_id: @season.id).first
        model_row.id = db_row.id if db_row
        # Override the Import::Entity with the actual row:
        @data['badge'][entity_key] = commit_and_log(model_row)
      end

      @data['badge']
    end
    #-- ------------------------------------------------------------------------
    #++

    # TODO: relay data, any?
    # TODO: swimmers for relay data, any?
    # TODO: lap data, any?
    # TODO: scores data, any?
    #-- ------------------------------------------------------------------------
    #++

    # Commits the changes for the specified model row.
    #
    # If <tt>model_row</tt> has already an ID, it will be checked for update changes;
    # otherwise a new row will be created.
    #
    # A column will be considered to be changed if it qualifies for #difference_with_db.
    # Updates the internal <tt>@sql_log</tt> member.
    #
    # In order to automatize the most, rows having the read-only column set to true
    # won't be skipped and will be updated as the others.
    #
    # == Params:
    # - <tt>model_row</tt>: the row Model instance to be processed
    #
    # == Returns
    # The newly updated or created <tt>model_row</tt>.
    #
    def commit_and_log(model_row)
      # == INSERT ==
      if model_row.valid? && model_row.id.blank?
        model_row.save!
        @sql_log << SqlMaker.new(row: model_row).log_insert

      # == UPDATE ==
      elsif model_row.id.present?
        changes = self.class.difference_with_db(model_row)
        return model_row if changes.blank?

        db_row = model_row.class.find_by(id: model_row.id)
        # WARNING: DO NOT honor here the read_only? check commented-out below
        # or the update will be skipped.
        # > return db_row if db_row.respond_to?(:read_only?) && db_row.read_only?

        # Apply the changes & save:
        changes.each { |column, value| db_row.send("#{column}=", value) }
        db_row.save!
        model_row = db_row
        @sql_log << SqlMaker.new(row: model_row).log_update

      elsif !model_row.valid?
        raise StandardError, "Invalid #{model_row.class} row!"
      end
      # (else: don't do anything)

      model_row
    end
  end
end
