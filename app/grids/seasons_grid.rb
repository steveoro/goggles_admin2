# frozen_string_literal: true

# = SeasonsGrid
#
# DataGrid used to manage GogglesDb::Season rows.
#
class SeasonsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Unscoped data_domain read accessor
  def unscoped
    data_domain
  end

  filter(:id, :integer)
  filter(:description)
  filter(:begin_date, :date)
  filter(:end_date, :date)
  filter(:header_year)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:description)
  column(:begin_date)
  column(:end_date)
  column(:season_type_id, align: :right, mandatory: true)

  column(:header_year)
  column(:edition)
  column(:edition_type_id, align: :right, mandatory: true)
  column(:timing_type_id, align: :right, mandatory: true)
  column(:rules)
  column(:individual_rank)
  column(:badge_fee)

  actions_column(edit: true, destroy: false, mandatory: true)
end
