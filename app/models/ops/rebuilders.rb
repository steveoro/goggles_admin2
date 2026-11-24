# frozen_string_literal: true

module Ops
  #
  # = Ops::Rebuilders
  #
  # Registry of the callables run by 'rake ops:rebuild' to recompute the ops DB contents that can be
  # derived from other sources (disk, MySQL). Later features register their reconcilers at boot,
  # inside a +to_prepare+ block (this module is reloadable in development):
  #
  #   Rails.application.config.to_prepare do
  #     Ops::Rebuilders.register(:outbox, -> { Outbox::Reconciler.call })
  #   end
  #
  module Rebuilders
    @registry = {}
    @mutex = Mutex.new

    class << self
      # Registers (or replaces) the callable for +name+.
      def register(name, callable = nil, &block)
        callable ||= block
        raise ArgumentError, 'a callable is required' unless callable.respond_to?(:call)

        @mutex.synchronize { @registry[name.to_sym] = callable }
      end

      def unregister(name)
        @mutex.synchronize { @registry.delete(name.to_sym) }
      end

      # Hash name => callable (a copy).
      def all
        @mutex.synchronize { @registry.dup }
      end

      def names
        all.keys
      end

      # Runs every registered rebuilder (or the given one); returns a Hash name => result.
      def run!(only: nil)
        selected = all
        selected = selected.slice(only.to_sym) if only
        selected.transform_values(&:call)
      end
    end
  end
end
