# frozen_string_literal: true

module Ops
  #
  # = Ops::SessionStoreSetup
  #
  # Moves the web sessions (activerecord-session_store) from the MySQL primary to the local ops DB (table
  # 'sessions', phase 14), so that the operator stays signed in while a guided restore drops and reloads MySQL.
  #
  # - OpsSession: the gem's SqlBypass session class pointed to the ops pool (Ops::ApplicationRecord). The gem's own
  #   ActiveRecord::SessionStore::Session can't use +connects_to+, and SqlBypass memoizes ActiveRecord::Base's
  #   connection (its +connection_pool+ writer is never read), so every query here leases an ops connection itself.
  #   It also writes the timestamps (SqlBypass doesn't).
  # - Router: the object installed as ActionDispatch::Session::ActiveRecordStore.session_class (see
  #   config/initializers/session_store.rb). On each call it picks OpsSession while the ops DB is ready and falls
  #   back to the MySQL ActiveRecord::SessionStore::Session otherwise (ops DB not configured, missing or not migrated):
  #   the app keeps working before 'bin/rails ops:prepare', at the price of one more sign-in when it switches.
  #
  # Data format: the gem's serializer (config/initializers/cookies_serializer.rb sets :json for both classes).
  # The MySQL 'sessions' table belongs to the engine schema and is left in place.
  #
  module SessionStoreSetup
    TABLE = 'sessions'

    # SqlBypass session rows in the ops DB.
    class OpsSession < ActiveRecord::SessionStore::SqlBypass
      class << self
        def connection_pool
          Ops::ApplicationRecord.connection_pool
        end

        # (Kept for the gem's ClassMethods helpers; this class never memoizes a connection.)
        def connection
          Ops::ApplicationRecord.lease_connection
        end

        # The session with the given (private) id, or nil.
        def find_by_session_id(session_id)
          record = with_connection do |conn|
            conn.select_one("SELECT data FROM #{TABLE} WHERE session_id = #{conn.quote(session_id.to_s)}", 'Ops session load')
          end
          new(session_id:, retrieved_by: session_id, serialized_data: record['data']) if record
        end

        def with_connection(&)
          Ops::ApplicationRecord.with_connection(&)
        end
      end

      def connection
        self.class.connection
      end

      # Inserts or updates the row (returns true); false when the data was never loaded.
      def save # rubocop:disable Naming/PredicateMethod
        return false unless loaded?

        serialized = self.class.serialize(data)
        self.class.with_connection do |conn|
          now = conn.quote(Time.now.utc)
          if @new_record
            @new_record = false
            conn.insert("INSERT INTO #{TABLE} (session_id, data, created_at, updated_at) " \
                        "VALUES (#{conn.quote(session_id.to_s)}, #{conn.quote(serialized)}, #{now}, #{now})", 'Ops session create')
          else
            conn.update("UPDATE #{TABLE} SET data = #{conn.quote(serialized)}, session_id = #{conn.quote(session_id.to_s)}, " \
                        "updated_at = #{now} WHERE session_id = #{conn.quote(@retrieved_by.to_s)}", 'Ops session update')
          end
        end
        @retrieved_by = session_id
        @data_changed = false
        true
      end

      def destroy
        return if @new_record

        self.class.with_connection do |conn|
          conn.delete("DELETE FROM #{TABLE} WHERE session_id = #{conn.quote(session_id.to_s)}", 'Ops session destroy')
        end
      end
    end

    # Session class proxy installed in the session store: OpsSession while the ops DB is ready, else MySQL.
    module Router
      module_function

      def find_by_session_id(session_id)
        session_class.find_by_session_id(session_id) # rubocop:disable Rails/DynamicFindBy
      end

      def new(attributes)
        session_class.new(attributes)
      end

      # The class serving the current call.
      def session_class
        SessionStoreSetup.ops_ready? ? OpsSession : ActiveRecord::SessionStore::Session
      end
    end

    module_function

    # Installs the Router (to_prepare: re-run after each code reload in development).
    def install!
      require 'active_record/session_store/session' # (sets the gem's default class first: overridden right after)
      ActionDispatch::Session::ActiveRecordStore.session_class = Router
    end

    # True when the sessions go to the ops DB.
    def ops_ready?
      Ops::Database.configured? && Ops.available?
    end

    # Number of session rows in the ops DB (nil without it).
    def count
      Ops.safely { OpsSession.with_connection { |conn| conn.select_value("SELECT COUNT(*) FROM #{TABLE}").to_i } if ops_ready? }
    end

    # Deletes the ops session rows not updated for +older_than+; returns the deleted count (nil without the ops DB).
    def trim!(older_than: 30.days)
      Ops.safely do
        next unless ops_ready?

        OpsSession.with_connection do |conn|
          conn.delete("DELETE FROM #{TABLE} WHERE updated_at < #{conn.quote(older_than.ago.utc)}", 'Ops session trim')
        end
      end
    end
  end
end
