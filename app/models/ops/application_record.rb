# frozen_string_literal: true

module Ops
  #
  # = Ops::ApplicationRecord
  #
  # Abstract parent of every model stored in the local SQLite ops DB (see Ops::Database).
  #
  # The connection is declared only when the 'ops' entry exists in config/database.yml, so that
  # (eager) loading never breaks the boot when the entry is missing; in that case any query
  # raises Ops::NotConfiguredError instead of silently falling back to the primary (MySQL) DB.
  # Callers should check Ops.available? (or wrap the access in Ops.safely).
  #
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    if Ops::Database.configured?
      connects_to database: { writing: :ops }
    else
      def self.connection_pool
        raise Ops::NotConfiguredError, "no 'ops' entry for '#{Rails.env}' in config/database.yml"
      end
    end
  end
end
