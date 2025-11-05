# frozen_string_literal: true

module Import
  #
  # = PhaseCommitLogger
  #
  # Dedicated logger for Phase 6 commit operations. Creates a .log file alongside
  # the SQL output with detailed validation errors, entity keys, and statistics.
  #
  # @author Steve A.
  #
  class PhaseCommitLogger
    attr_reader :log_path, :entries

    def initialize(log_path:)
      @log_path = log_path
      @entries = []
    end

    # Log a successful entity commit
    def log_success(entity_type:, action:, entity_key: nil, entity_id: nil)
      entries << {
        level: :info,
        entity_type: entity_type,
        entity_key: entity_key,
        entity_id: entity_id,
        action: action,
        timestamp: Time.current
      }
    end

    # Log a validation error with detailed message
    def log_validation_error(entity_type:, entity_key: nil, entity_id: nil, model_row: nil, error: nil)
      error_details = if model_row && !model_row.valid?
                        GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                      elsif error
                        error.message
                      else
                        'Unknown validation error'
                      end

      entries << {
        level: :error,
        entity_type: entity_type,
        entity_key: entity_key,
        entity_id: entity_id,
        error: error_details,
        timestamp: Time.current
      }
    end

    # Log a general error
    def log_error(message:, entity_type: nil, entity_key: nil)
      entries << {
        level: :error,
        entity_type: entity_type,
        entity_key: entity_key,
        message: message,
        timestamp: Time.current
      }
    end

    # Write the log file with formatted entries and stats summary
    def write_log_file(stats:)
      File.open(log_path, 'w') do |f|
        f.puts '=' * 80
        f.puts "Phase 6 Commit Log - #{Time.current}"
        f.puts '=' * 80
        f.puts

        # Write stats summary
        f.puts '=== STATISTICS ==='
        stats.each do |key, value|
          next if key == :errors

          f.puts "  #{key}: #{value}"
        end
        f.puts

        # Write errors summary
        if stats[:errors].any?
          f.puts "=== ERRORS SUMMARY (#{stats[:errors].count}) ==="
          stats[:errors].each { |err| f.puts "  - #{err}" }
          f.puts
        end

        # Write detailed log entries
        f.puts '=== DETAILED LOG ==='
        entries.each do |entry|
          case entry[:level]
          when :info
            f.puts "[#{entry[:timestamp]}] INFO: #{entry[:action]} #{entry[:entity_type]}"
            f.puts "  Key: #{entry[:entity_key]}" if entry[:entity_key]
            f.puts "  ID: #{entry[:entity_id]}" if entry[:entity_id]
          when :error
            f.puts "[#{entry[:timestamp]}] ERROR: #{entry[:entity_type]}"
            f.puts "  Key: #{entry[:entity_key]}" if entry[:entity_key]
            f.puts "  ID: #{entry[:entity_id]}" if entry[:entity_id]
            f.puts "  Error: #{entry[:error] || entry[:message]}"
          end
          f.puts
        end

        f.puts '=' * 80
        f.puts "Log completed at #{Time.current}"
        f.puts '=' * 80
      end

      Rails.logger.info("[PhaseCommitLogger] Log file written to: #{log_path}")
    end
  end
end
