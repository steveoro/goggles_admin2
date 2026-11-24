# frozen_string_literal: true

module DataFix
  module Verdicts
    #
    # = DataFix::Verdicts::Phase3 (swimmers + badges)
    #
    # Blocked: a new swimmer without gender, year of birth or category (it can't be created); a badge whose team
    # key is missing from phase 2. Review: per DataFix::ReviewRules.swimmer_needs_review? (duplicate badges are
    # computed in memory, as the review page does); more than 40% new swimmers; relay legs still to enrich.
    #
    class Phase3 < Base
      PHASE = 3

      protected

      def check # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        swimmers = Array(data['swimmers']).map(&:dup)
        DataFix::Phase3Harmonizer.annotate_swimmer_badge_duplicates!(swimmers)

        incomplete = swimmers.select { |swimmer| DataFix::ReviewRules.incomplete_new_swimmer?(swimmer) }
        blocked!(:new_swimmer_incomplete, count: incomplete.size, details: incomplete.pluck('key'))
        team_keys = Array(pipeline.phase_data(2)['teams']).to_set { |team| team['key'] }
        orphan_badges = Array(data['badges']).reject { |badge| badge['team_key'].present? && team_keys.include?(badge['team_key']) }
        blocked!(:badge_team_missing, count: orphan_badges.size, details: orphan_badges.pluck('team_key').uniq) if pipeline.phase_exists?(2)

        review_rows = swimmers.select { |swimmer| DataFix::ReviewRules.swimmer_needs_review?(swimmer) } - incomplete
        review!(:swimmers_review, count: review_rows.size, details: review_rows.pluck('key'))
        review!(:too_many_new_swimmers) if DataFix::ReviewRules.too_many_new_swimmers?(swimmers)
        review!(:relay_enrichment, count: relay_enrichment_count)

        new_rows = swimmers.select { |swimmer| swimmer['swimmer_id'].blank? }
        counts.merge!('swimmers' => swimmers.size, 'matched' => swimmers.size - new_rows.size, 'new' => new_rows.size,
                      'review' => review_rows.size, 'badges' => Array(data['badges']).size,
                      'confirmed' => swimmers.count { |swimmer| DataFix::ReviewRules.confirmed?(swimmer) })
        new_entities['swimmers'] = swimmers.select { |swimmer| DataFix::ReviewRules.confidently_new_swimmer?(swimmer) }
                                           .map { |swimmer| DataFix::ReviewRules.new_swimmer_entry(swimmer) }
      end

      private

      # Relay legs still lacking data (same filter as the review page, new-only legs hidden).
      def relay_enrichment_count
        return pipeline.relay_enrichment_count unless pipeline.relay_enrichment_count.nil?

        detector = ::Phase3::RelayEnrichmentDetector.new(
          source_path: pipeline.source_path, phase3_swimmers: Array(data['swimmers']), season: pipeline.season,
          meeting_date: pipeline.meeting_date, categories_cache: pipeline.categories_cache
        )
        DataFix::RelayEnrichmentFilter.filter_relay_enrichment_summary(detector.detect, false, data).size
      rescue StandardError => e
        Rails.logger.warn("[DataFix::Verdicts::Phase3] relay enrichment check skipped: #{e.message}")
        0
      end
    end
  end
end
