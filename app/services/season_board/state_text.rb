# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::StateText
  #
  # Translated label of a board row state with its details (SeasonBoard::RowComponent, the inbox sources):
  # - :prepare_failed  => "Preparation failed at step 4: <message>"
  # - :needs_review    => "Needs review at step 3 · 4 issues" ("Blocked at step 5 · 1 issue" when blocked)
  # - :ready_to_commit => "Ready to commit · +2 teams, +37 swimmers"
  # - any other state  => its plain label (season_board.states.<state>, %{phase} for :in_review).
  # +detail+: the row's state_detail Hash (Symbol or String keys).
  #
  module StateText
    MESSAGE_LENGTH = 120

    module_function

    def label(state, detail = {})
      detail = (detail || {}).to_h.symbolize_keys
      case state&.to_sym
      when :prepare_failed then prepare_failed_label(detail)
      when :needs_review then needs_review_label(detail)
      when :ready_to_commit then I18n.t('season_board.state_details.ready_to_commit', entities: new_entities(detail))
      else I18n.t("season_board.states.#{state}", phase: detail[:phase])
      end
    end

    # "+2 teams, +37 swimmers" (or "nothing new to create").
    def new_entities(detail)
      teams = detail[:new_teams].to_i
      swimmers = detail[:new_swimmers].to_i
      return I18n.t('season_board.state_details.no_new_entities') if teams.zero? && swimmers.zero?

      [(I18n.t('season_board.state_details.new_teams', count: teams) if teams.positive?),
       (I18n.t('season_board.state_details.new_swimmers', count: swimmers) if swimmers.positive?)].compact.join(', ')
    end

    def prepare_failed_label(detail)
      message = detail[:message].to_s.truncate(MESSAGE_LENGTH)
      key = detail[:phase].present? ? 'prepare_failed' : 'prepare_failed_no_phase'
      text = I18n.t("season_board.state_details.#{key}", phase: detail[:phase])
      message.present? ? "#{text}: #{message}" : text
    end

    def needs_review_label(detail)
      key = detail[:blocked] ? 'blocked' : 'needs_review'
      step = I18n.t("season_board.state_details.#{key}", step: detail[:step] || 1)
      count = detail[:count].to_i
      count.positive? ? "#{step} · #{I18n.t('season_board.state_details.issues', count:)}" : step
    end
  end
end
