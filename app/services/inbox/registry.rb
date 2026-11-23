# frozen_string_literal: true

module Inbox
  #
  # = Inbox::Registry
  #
  # Ordered list of the Inbox::Source classes merged by Inbox::Builder. Sources are registered in
  # config/initializers/inbox.rb inside <tt>Rails.application.config.to_prepare</tt> (this class is reloadable).
  #
  # == Usage
  #   Inbox::Registry.register(Inbox::Sources::PendingSql)          # appended (or updated in place, same key)
  #   Inbox::Registry.replace(:pending_sql, Outbox::InboxSource)     # phase 07: same slot, new class
  #   Inbox::Registry.sources                                        # => [Class, ...] in order
  #
  class Registry
    class << self
      # Registers the source class under its key (the class' own +key+ unless given). Registering the same
      # key again replaces the class in place (idempotent across code reloads). Returns the class.
      def register(klass, key: nil)
        key = (key || klass.key).to_sym
        entries[key] = klass
        klass
      end

      # Replaces the source registered under +key+ with +klass+, keeping its position; appends it when the key is
      # not registered yet. Returns the class.
      def replace(key, klass)
        entries[key.to_sym] = klass
        klass
      end

      # Removes the source registered under +key+ (returns the removed class, or nil).
      def unregister(key)
        entries.delete(key.to_sym)
      end

      # Source classes, in registration order.
      def sources
        entries.values
      end

      # Registered keys, in order.
      delegate :keys, to: :entries

      # Key under which +klass+ is registered (nil when not registered).
      def key_for(klass)
        entries.key(klass)
      end

      # Forgets every source (specs).
      def clear!
        entries.clear
      end

      private

      def entries
        @entries ||= {}
      end
    end
  end
end
