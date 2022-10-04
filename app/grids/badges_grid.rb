# frozen_string_literal: true

# = BadgesGrid
#
# DataGrid used to manage GogglesDb::Badge rows.
#
class BadgesGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:team_id, :integer, header: 'Team ID')
  filter(:team_affiliation_id, :integer, header: 'Team Aff. ID')
  filter(:season_id, :integer, header: 'Season ID')
  filter(:swimmer_id, :integer, header: 'Swimmer ID')
  filter(:off_gogglecup, :boolean)
  filter(:fees_due, :boolean)
  filter(:badge_due, :boolean)
  filter(:relays_due, :boolean)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:number)
  column(
    :season_type_name, header: 'Season', align: :right, html: true, mandatory: true,
                       order: proc { |scope| scope.sort { |a, b| a.season_type.code <=> b.season_type.code } }
  ) do |asset|
    "<small><i>#{asset.season_type.code}</i></small> - #{asset.season.id}".html_safe
  end
  column(:swimmer_id, align: :right, mandatory: true)
  column(
    :swimmer_name, header: 'Name', html: true, mandatory: true,
                   order: proc { |scope| scope.sort { |a, b| a.swimmer.complete_name <=> b.swimmer.complete_name } }
  ) do |asset|
    "<small>#{asset.swimmer.complete_name}</small>".html_safe
  end
  column(:team_id, align: :right, mandatory: true)
  column(
    :team_name, header: 'Name', html: true, mandatory: true,
                order: proc { |scope| scope.sort { |a, b| a.team.name <=> b.team.name } }
  ) do |asset|
    "<small>#{asset.team.name}<br/>TA: <b>#{asset.team_affiliation_id}</b></small>".html_safe
  end

  column(:category_type_id, align: :right)
  column(:entry_time_type_id, align: :right)
  column(:final_rank, align: :right)

  boolean_column(:off_gogglecup, align: :center, mandatory: true, order: false)
  boolean_column(:fees_due, align: :center, mandatory: true, order: false)
  boolean_column(:badge_due, align: :center, mandatory: true, order: false)
  boolean_column(:relays_due, align: :center, mandatory: true, order: false)

  actions_column(edit: true, destroy: true, mandatory: true)
end
