# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::Registry
  #
  # Catalogue of the maintenance operations (Maintenance::Operation subclasses), in display order. Phase 13 adds its
  # operations here.
  #
  # == Usage
  #   Maintenance::Registry.fetch('badge.merge')             # => Maintenance::Operations::BadgeMerge
  #   Maintenance::Registry.for_finding(finding)             # => the operations offering a Fix button on the finding
  #
  module Registry
    CLASS_NAMES = %w[
      Maintenance::Operations::MeetingSetCancelled
      Maintenance::Operations::BadgeMerge
      Maintenance::Operations::ResultsNullSwimmersFix
      Maintenance::Operations::ResultsDedupe
      Maintenance::Operations::RanksRecompute
      Maintenance::Operations::SeasonBoardBackfill
      Maintenance::Operations::SwimmerMerge
      Maintenance::Operations::TeamMerge
    ].freeze

    module_function

    # Every operation class, in display order.
    def all = CLASS_NAMES.map(&:constantize)

    def keys = all.map(&:key)

    # The operation class for +key+ (nil when unknown).
    def find(key) = all.find { |klass| klass.key == key.to_s }

    # The operation class for +key+; raises KeyError when unknown.
    def fetch(key) = find(key) || raise(KeyError, "unknown maintenance operation '#{key}'")

    # The operations fixing the findings of +check_key+.
    def for_check(check_key) = all.select { |klass| klass.fixes.include?(check_key.to_s) }

    # The operations offered on +finding+ (Ops::HealthFinding).
    def for_finding(finding)
      for_check(finding.check_key).select { |klass| klass.offer_for?(finding) }
    end
  end
end
