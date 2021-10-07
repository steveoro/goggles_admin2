# frozen_string_literal: true

# = TeamAffiliationsGrid
#
# DataGrid used to manage GogglesDb::TeamAffiliation rows.
#
class TeamAffiliationsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Unscoped data_domain read accessor
  def unscoped
    data_domain
  end

  filter(:id, :integer)
  filter(:season_id, :integer)
  filter(:name, :string, header: 'Name (~)') do |value, scope|
    scope.select do |row|
      (row.name =~ /#{value}/i) || (row.team.name =~ /#{value}/i) ||
        (row.team.editable_name =~ /#{value}/i)
    end
  end
  filter(:compute_gogglecup, :boolean)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)

  column(:name, mandatory: true)
  column(:number)
  column(:compute_gogglecup, align: :right)
  column(:team_id, align: :right, mandatory: true)
  column(:season_id, align: :right, mandatory: true)
  column(:autofilled, align: :right)

  actions_column(edit: true, destroy: true, mandatory: true)
end
