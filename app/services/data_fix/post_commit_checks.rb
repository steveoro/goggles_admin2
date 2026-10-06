# frozen_string_literal: true

module DataFix
  # PostCommitChecks: read-only integrity checks run after a successful Phase 6
  # commit and shown on the commit report — badge-per-season merge candidates
  # and duplicate result rows.
  module PostCommitChecks
    extend self

    def build_post_commit_checks_report(season_id)
      season = GogglesDb::Season.find_by(id: season_id.to_i)
      return { error: "Unable to run post-commit checks: invalid season '#{season_id}'." } unless season

      badge_check = build_badge_season_check_report(season)
      duplicate_check = build_duplicate_results_check_report(season)
      overall_status = if badge_check[:status] == 'error' || duplicate_check[:status] == 'error'
                         'error'
                       elsif badge_check[:status] == 'warning'
                         'warning'
                       else
                         'ok'
                       end

      {
        season_id: season.id,
        overall_status: overall_status,
        badge_season_check: badge_check,
        duplicate_results_check: duplicate_check
      }
    rescue StandardError => e
      Rails.logger.error("[DataFix::PostCommitChecks] Post-commit checks failed: #{e.message}")
      { error: "Post-commit checks failed: #{e.message}" }
    end

    def build_badge_season_check_report(season)
      checker = Merge::BadgeSeasonChecker.new(season: season)
      checker.run

      sure_count = checker.sure_badge_merges.keys.size
      possible_count = checker.possible_badge_merges.keys.size
      status = if sure_count.positive?
                 'error'
               elsif possible_count.positive?
                 'warning'
               else
                 'ok'
               end

      {
        status: status,
        sure_badge_merges_count: sure_count,
        possible_badge_merges_count: possible_count,
        multi_badges_count: checker.multi_badges.keys.size,
        possible_team_merges_count: checker.possible_team_merges.size,
        relay_badges_count: checker.relay_badges.size,
        relay_only_badges_count: checker.relay_only_badges.size,
        sure_badge_merges: serialize_badge_merges(checker.sure_badge_merges),
        possible_badge_merges: serialize_badge_merges(checker.possible_badge_merges)
      }
    end

    def serialize_badge_merges(merges_hash)
      swimmer_ids = merges_hash.keys
      swimmers_by_id = GogglesDb::Swimmer.where(id: swimmer_ids).index_by(&:id)

      entries = merges_hash.map do |swimmer_id, badge_list|
        {
          swimmer_id: swimmer_id,
          swimmer_name: swimmers_by_id[swimmer_id]&.complete_name,
          badges: badge_list.map do |badge|
            {
              id: badge.id,
              team_id: badge.team_id,
              team_name: badge.team&.name,
              category_code: badge.category_type&.code
            }
          end
        }
      end
      entries.sort_by { |entry| entry[:swimmer_id] }
    end

    def build_duplicate_results_check_report(season)
      cleaner = Merge::DuplicateResultCleaner.new(season: season, autofix: false)
      totals = {
        mirs: 0,
        laps: 0,
        mrss: 0,
        relay_laps: 0,
        mrrs: 0
      }
      meetings_with_findings = []

      cleaner.meetings_to_process.each do |meeting|
        dup_mirs = cleaner.find_duplicate_mirs(meeting.id)
        dup_laps = cleaner.find_duplicate_laps(meeting.id)
        dup_mrss = cleaner.find_duplicate_mrss(meeting.id)
        dup_relay_laps = cleaner.find_duplicate_relay_laps(meeting.id)
        dup_mrrs = cleaner.find_duplicate_mrrs(meeting.id)
        next if dup_mirs.empty? && dup_laps.empty? && dup_mrss.empty? && dup_relay_laps.empty? && dup_mrrs.empty?

        counts = {
          mirs: dup_mirs.size,
          laps: dup_laps.size,
          mrss: dup_mrss.size,
          relay_laps: dup_relay_laps.size,
          mrrs: dup_mrrs.size
        }
        totals.each_key { |key| totals[key] += counts[key] }

        meetings_with_findings << {
          meeting_id: meeting.id,
          meeting_description: meeting.description,
          counts: counts,
          duplicate_mirs: serialize_duplicate_mirs(dup_mirs)
        }
      end

      {
        status: totals.values.sum.positive? ? 'error' : 'ok',
        totals: totals,
        meetings_with_findings_count: meetings_with_findings.size,
        meetings_with_findings: meetings_with_findings
      }
    end

    def serialize_duplicate_mirs(dup_mirs)
      dup_mirs.map do |dup|
        {
          swimmer_id: dup[:swimmer].id,
          swimmer_name: dup[:swimmer].complete_name,
          swimmer_year_of_birth: dup[:swimmer].year_of_birth,
          meeting_program_id: dup[:meeting_program_id],
          timing_match: dup[:timing_match],
          mirs: dup[:mirs].map do |mir|
            {
              id: mir.id,
              timing: mir.to_timing.to_s,
              team_id: mir.team_id,
              team_name: mir.team&.editable_name,
              badge_id: mir.badge_id,
              badge_missing: !GogglesDb::Badge.exists?(id: mir.badge_id),
              badge_label: mir.badge&.decorate&.short_label
            }
          end
        }
      end
    end
  end
end
