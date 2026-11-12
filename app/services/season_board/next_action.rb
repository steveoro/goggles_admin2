# frozen_string_literal: true

module SeasonBoard
  # Next action suggested for a Row: +kind+ (Symbol, see StateResolver::ACTIONS) and the
  # +params+ (Hash with Symbol keys) needed to run it.
  NextAction = Data.define(:kind, :params) do
    delegate :[], to: :params
  end
end
