# frozen_string_literal: true

module GogglesCup
  # Resolves the primary-team context of the GogglesCup page for the current user.
  #
  # Shaped to be reusable when this UI is cloned to goggles_main (mirroring the
  # managed-teams resolution already used there by GoggleCupsController):
  # - admins can freely choose any team (#can_choose_any_team? => true and
  #   #managed_teams is left empty, meaning "unrestricted");
  # - managers get the list of teams they can manage;
  # - #default_team is the team to preselect for the shown championship year:
  #   1. the team of the first ManagedAffiliation of the user for the seasons
  #      belonging to that championship year;
  #   2. the team of the Badge for the same seasons of the Swimmer associated
  #      to the user (if any);
  #   3. +nil+ (free choice).
  class ManagedTeamResolver
    # == Params:
    # - user:        the current GogglesDb::User (required)
    # - season_year: the championship year currently shown (defaults to the
    #                current championship year)
    def initialize(user:, season_year: nil)
      @user = user
      @season_year = season_year.presence&.to_i || GogglesDb::Season.current_championship_year(GogglesDb::SeasonType.mas_fin)
    end

    # Returns true when the user can pick any team (admin grants).
    def can_choose_any_team?
      @can_choose_any_team ||= GogglesDb::GrantChecker.admin?(@user)
    end

    # Returns the list of manageable teams for the user (any season).
    # Left empty for admins (meaning: unrestricted choice).
    def managed_teams
      @managed_teams ||= can_choose_any_team? ? GogglesDb::Team.none : GogglesDb::Team.where(id: managed_team_ids)
    end

    # Returns the distinct team ids the user manages (any season).
    def managed_team_ids
      @managed_team_ids ||= GogglesDb::ManagedAffiliation
                            .where(user_id: @user.id)
                            .joins(:team_affiliation)
                            .distinct
                            .pluck('team_affiliations.team_id')
    end

    # Returns the default primary Team for the shown championship year, or +nil+.
    def default_team
      @default_team ||= managed_affiliation_team || badge_team
    end

    private

    def shown_seasons
      @shown_seasons ||= GogglesDb::Season.for_championship_year(@season_year)
    end

    def managed_affiliation_team
      GogglesDb::ManagedAffiliation
        .where(user_id: @user.id)
        .joins(team_affiliation: :season)
        .merge(shown_seasons)
        .order('managed_affiliations.id')
        .first&.team_affiliation&.team
    end

    def badge_team
      return nil if @user&.swimmer_id.blank?

      GogglesDb::Badge
        .joins(:season)
        .merge(shown_seasons)
        .where(swimmer_id: @user.swimmer_id)
        .first&.team
    end
  end
end
