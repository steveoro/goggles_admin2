# frozen_string_literal: true

module Outbox
  #
  # = Outbox::PushPlan
  #
  # What a push would send (the confirmation page, OutboxController#push_new) and the ordering guard re-checked
  # by OutboxController#push before the run is created. Read only: no remote call (the controller adds the fresh
  # ping), no write.
  #
  # == Selection
  # - scope 'all_pending' => every pending script, in seq order (held scripts are never pushed);
  # - scope 'next'        => the lowest-seq pending script;
  # - ids                 => those scripts (pending only), in seq order.
  #
  # == Ordering guard
  # A selected script may not jump a lower-seq script in a blocking state (pending, pushing, in_doubt) that is not
  # selected too, unless +override_order+ (an explicit operator choice). Held scripts never block.
  #
  # == Target
  # The configured API (Shell::APITarget). Its environment is the one reported by the API in its last 'status'
  # answer (phase 08: the confirmation page pings it first), else the port guess, unverified. The operator types the
  # environment label (#label_required?) only for an unverified or non-production target.
  #
  class PushPlan
    SCOPES = %w[all_pending next].freeze

    attr_reader :scope, :ids, :override_order, :target

    def initialize(ids: nil, scope: nil, override_order: false, target: Shell::APITarget.current)
      @ids = Array(ids).compact_blank.map(&:to_i).uniq
      @scope = SCOPES.include?(scope.to_s) ? scope.to_s : nil
      @override_order = ActiveModel::Type::Boolean.new.cast(override_order) || false
      @target = target
    end

    # The scripts to push, in seq order.
    def scripts
      @scripts ||= begin
        relation = Ops::SqlScript.pending.ordered
        case scope
        when 'all_pending' then relation.to_a
        when 'next' then relation.limit(1).to_a
        else ids.any? ? relation.where(id: ids).to_a : []
        end
      end
    end

    delegate :empty?, to: :scripts
    def script_ids = scripts.map(&:id)
    def total_bytes = scripts.sum { |script| script.byte_size.to_i }

    # Lower-seq scripts in a blocking state that are not part of the selection.
    def blockers
      return [] if empty?

      @blockers ||= Ops::SqlScript.blocking_before(scripts.last.seq).where.not(id: script_ids).to_a
    end

    def blocked? = blockers.any?
    def allowed? = !empty? && (!blocked? || override_order)

    # Selected scripts changed after a previous push (they need a second look).
    def changed_after_push
      scripts.select(&:changed_after_push?)
    end

    delegate :url, to: :target, prefix: true

    # Environment of the target: reported by the API ('production', 'development', ...), else the port guess
    # ('production' or 'unknown').
    delegate :environment, to: :target

    # True when the environment was reported by the API itself.
    delegate :verified?, to: :target

    # The operator types the environment label for an unverified or non-production target.
    def label_required?
      !verified? || environment != 'production'
    end

    # True when +typed+ matches the environment label (when required).
    def label_confirmed?(typed)
      !label_required? || typed.to_s.strip.casecmp?(environment)
    end
  end
end
