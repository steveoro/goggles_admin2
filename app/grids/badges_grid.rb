# frozen_string_literal: true

# = BadgesGrid
#
# DataGrid used to manage GogglesDb::Badge rows.
#
class BadgesGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Unscoped data_domain read accessor
  def unscoped
    data_domain
  end

  filter(:id, :integer)
  filter(:swimmer_id, :integer)
  filter(:team_id, :integer)
  filter(:season_id, :integer)
  filter(:off_gogglecup, :boolean)
  filter(:fees_due, :boolean)
  filter(:badge_due, :boolean)
  filter(:relays_due, :boolean)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:number)
  column(:season_id, align: :right, mandatory: true)
  column(:swimmer_id, align: :right, mandatory: true)
  column(:team_id, align: :right, mandatory: true)
  column(:team_affiliation_id, align: :right)

  column(:category_type_id, align: :right)
  column(:entry_time_type_id, align: :right)
  column(:final_rank, align: :right)

  boolean_column(:off_gogglecup, align: :center, mandatory: true)
  boolean_column(:fees_due, align: :center, mandatory: true)
  boolean_column(:badge_due, align: :center, mandatory: true)
  boolean_column(:relays_due, align: :center, mandatory: true)

  actions_column(edit: true, destroy: true, mandatory: true)
end
