# frozen_string_literal: true

module Outbox
  #
  # = Outbox::RemoteStatus
  #
  # Maps the answer of <tt>GET import_queue/:id</tt> for a pushed SQL batch to its outcome on the server
  # (goggles_main 0.10.81 job + goggles_api 0.10.81, capability 'iq_batch_outcome'; no new column, the encoding is):
  #
  #   outcome  | done  | process_runs | error_messages
  #   ---------+-------+--------------+---------------
  #   :queued  | false | 0            | blank
  #   :running | false | > 0          | blank
  #   :applied | true  | any          | blank
  #   :failed  | any   | any          | present        (the MariaDB error text, or 'interrupted: outcome unknown')
  #   :gone    | (null or empty body: the row no longer exists)
  #
  # Without the capability only :gone is meaningful (the old job marks a row done before running it and deletes it
  # on its next run): Outbox::RemoteStatusJob then keeps the phase 07 behaviour ('executed_unreported').
  #
  module RemoteStatus
    OUTCOMES = %i[queued running applied failed gone].freeze

    module_function

    # Outcome Symbol for the parsed JSON answer (Hash, nil or anything else => :gone when blank).
    def map(json)
      return :gone if json.blank? || !json.is_a?(Hash)
      return :failed if json['error_messages'].to_s.strip.present?
      return :applied if truthy?(json['done'])

      json['process_runs'].to_i.positive? ? :running : :queued
    end

    # The server error text of a failed row (nil otherwise).
    def error_for(json)
      json.is_a?(Hash) ? json['error_messages'].to_s.strip.presence : nil
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value) == true
    end
  end
end
