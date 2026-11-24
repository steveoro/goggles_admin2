# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::Registry
  #
  # Catalogue of the maintenance operations (Maintenance::Operation subclasses), in display order: the eight of phase
  # 11, then the nine of phase 13; then the read-only inspectors of phase 13 (Maintenance::Inspector, dry run only).
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
      Maintenance::Operations::MeetingMerge
      Maintenance::Operations::MeetingTeamFix
      Maintenance::Operations::BadgeTeamFix
      Maintenance::Operations::BadgeSwimmerFix
      Maintenance::Operations::MeetingPurge
      Maintenance::Operations::CodedNamesNormalize
      Maintenance::Operations::CategoriesClone
      Maintenance::Operations::StandardTimingsImport
      Maintenance::Operations::SeasonBadgeFix
    ].freeze

    # Read-only checks (the former 'check:*' reports), listed apart.
    INSPECTOR_CLASS_NAMES = %w[
      Maintenance::Inspectors::TeamCheck
      Maintenance::Inspectors::SwimmerCheck
      Maintenance::Inspectors::BadgeCheck
      Maintenance::Inspectors::SeasonBadges
      Maintenance::Inspectors::MapTeamBadges
      Maintenance::Inspectors::MapSwimmerMirs
      Maintenance::Inspectors::DupBadgesForTeam
      Maintenance::Inspectors::DupMIRBadges
    ].freeze

    module_function

    # Every operation class (fixes), in display order.
    def all = CLASS_NAMES.map(&:constantize)

    # Every inspector class, in display order.
    def inspectors = INSPECTOR_CLASS_NAMES.map(&:constantize)

    def keys = all.map(&:key)

    def inspector_keys = inspectors.map(&:key)

    # The operation (or inspector) class for +key+ (nil when unknown).
    def find(key) = (all + inspectors).find { |klass| klass.key == key.to_s }

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
