# frozen_string_literal: true

# = SeasonsGrid
#
# DataGrid used to manage GogglesDb::Season rows.
#
# rubocop:disable Rails/OutputSafety
class SeasonsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Unscoped data_domain read accessor
  def unscoped
    data_domain
  end

  filter(:id, :integer)
  filter(:description)
  filter(:header_year)
  filter(:begin_date, :date)
  filter(:end_date, :date)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:description)
  column(:begin_date)
  column(:end_date)
  column(
    :season_type_name, align: :right, html: true, mandatory: true,
                       order: proc { |scope| scope.sort { |a, b| a.season_type.short_name <=> b.season_type.short_name } }
  ) do |asset|
    "<b>#{asset.season_type.short_name}</b><br/><small><i>#{asset.description.truncate(32)}</i></small>".html_safe
  end
  column(:season_type_id, align: :right, mandatory: true)

  column(:header_year, mandatory: true)
  column(:edition, align: :right, mandatory: true)
  column(:edition_type_id, align: :right, mandatory: true)
  column(:timing_type_id, align: :right, mandatory: true)
  column(:rules)
  boolean_column(:individual_rank)
  column(:badge_fee)

  actions_column(edit: true, destroy: false, mandatory: true)
end
# rubocop:enable Rails/OutputSafety
