# frozen_string_literal: true

# = SeasonsGrid
#
# DataGrid used to manage GogglesDb::Season rows.
#
# rubocop:disable Rails/OutputSafety
class SeasonsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:season_type_id,
         :enum, header: 'SeasonType',
                select: proc { GogglesDb::SeasonType.all.map { |c| [c.code, c.id] } }) { |_value, scope| scope }
  filter(:header_year)
  filter(:begin_date, :date)
  filter(:end_date, :date)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:begin_date)
  column(:end_date)
  column(:season_type_id, align: :right, mandatory: true)
  column(
    :season_type_name, header: 'Name', html: true, mandatory: true,
                       order: proc { |scope| scope.sort { |a, b| a.season_type.short_name <=> b.season_type.short_name } }
  ) do |asset|
    "<small><i>#{asset.season_type.short_name}</i></small>".html_safe
  end

  column(:header_year, mandatory: true)
  column(:edition, align: :right, mandatory: true)
  column(:edition_type, html: true, mandatory: true) do |asset|
    "#{asset.edition_type_id} - <small><i>#{asset.edition_type.long_label}</i></small>".html_safe
  end
  column(:timing_type, html: true, mandatory: true) do |asset|
    "#{asset.timing_type_id} - <small><i>#{asset.timing_type.label}</i></small>".html_safe
  end
  column(:rules)
  boolean_column(:individual_rank)
  column(:badge_fee)

  actions_column(edit: true, destroy: false, mandatory: true)
end
# rubocop:enable Rails/OutputSafety
