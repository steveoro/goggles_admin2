# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::RakeTasks
  #
  # The adapters of the operational rake tasks (phase 13): each one is the former task body with its texts, prompts
  # and exits, where the strategy calls became operation runs (Maintenance::RakeRunner). One class per task, grouped by
  # namespace (Maintenance::RakeTasks::{MergeTasks, FixTasks, PurgeTasks, RecomputeTasks, NormalizeTasks, ImportTasks,
  # CheckTasks, SeasonBoardTasks}).
  #
  module RakeTasks
    TASKS = {
      'merge:swimmer' => 'MergeTasks::Swimmer', 'merge:team' => 'MergeTasks::Team', 'merge:meeting' => 'MergeTasks::Meeting',
      'merge:badge' => 'MergeTasks::Badge', 'merge:season_fix' => 'MergeTasks::SeasonFix',
      'merge:team_in_1_meeting' => 'MergeTasks::TeamInMeeting',
      'fix:team_in_badge' => 'FixTasks::TeamInBadge', 'fix:swimmer_in_badge' => 'FixTasks::SwimmerInBadge',
      'fix:nil_swimmers_in_results' => 'FixTasks::NilSwimmers',
      'purge:meeting' => 'PurgeTasks::Meeting',
      'recompute:ranks' => 'RecomputeTasks::Ranks',
      'normalize:coded_names' => 'NormalizeTasks::CodedNames',
      'import:categories' => 'ImportTasks::Categories', 'import:standard_timings' => 'ImportTasks::StandardTimings',
      'check:team' => 'CheckTasks::Team', 'check:swimmer' => 'CheckTasks::Swimmer', 'check:badge' => 'CheckTasks::Badge',
      'check:season' => 'CheckTasks::Season', 'check:map_team_badges' => 'CheckTasks::MapTeamBadges',
      'check:map_swimmer_mirs' => 'CheckTasks::MapSwimmerMirs', 'check:dup_badges_for_team' => 'CheckTasks::DupBadgesForTeam',
      'check:dup_mir_badges' => 'CheckTasks::DupMirBadges', 'check:dup_mir_swimmers' => 'CheckTasks::DupMirSwimmers',
      'season_board:backfill' => 'SeasonBoardTasks::Backfill'
    }.freeze

    module_function

    def task_names = TASKS.keys

    # The adapter class of +task_name+; raises KeyError when unknown.
    def fetch(task_name)
      "Maintenance::RakeTasks::#{TASKS.fetch(task_name.to_s)}".constantize
    end
  end
end
