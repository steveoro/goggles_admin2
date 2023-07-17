# frozen_string_literal: true

# = StandardTimingsGrid
#
# DataGrid used to manage GogglesDb::StandardTiming rows.
#
class StandardTimingsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:season_id, :integer, header: 'Season ID')
  filter(:gender_type_id,
         :enum, header: 'GenderType',
                select: proc { GogglesDb::GenderType.all.map { |c| [c.code, c.id] } }) { |_value, scope| scope }
  filter(:pool_type_id,
         :enum, header: 'PoolType',
                select: proc { GogglesDb::PoolType.all.map { |c| [c.code, c.id] } }) { |_value, scope| scope }
  filter(:event_type_id, :integer, header: 'EventType ID')
  filter(:category_type_id, :integer, header: 'CategoryType ID')

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)

  column(
    :season_id, header: 'Season', align: :right, html: true, mandatory: true,
                order: proc { |scope| scope.sort { |a, b| a.season_type.code <=> b.season_type.code } }
  ) do |asset|
    "<small><i>#{asset.season_type.code}</i></small> - #{asset.season.id}".html_safe
  end
  column(
    :gender_type_id, header: 'Gender', align: :center, html: true, mandatory: true,
                     order: proc { |scope| scope.sort { |a, b| a.gender_type.code <=> b.gender_type.code } }
  ) do |asset|
    "<small>#{asset.gender_type.code}</small>".html_safe
  end
  column(
    :pool_type_id, header: 'Pool', align: :center, html: true, mandatory: true,
                   order: proc { |scope| scope.sort { |a, b| a.pool_type.code <=> b.pool_type.code } }
  ) do |asset|
    "<small>#{asset.pool_type.code}</small>".html_safe
  end
  column(
    :event_type_id, header: 'Event', align: :right, html: true, mandatory: true,
                    order: proc { |scope| scope.sort { |a, b| a.event_type.code <=> b.event_type.code } }
  ) do |asset|
    "<small>#{asset.event_type.code} - <b>#{asset.event_type_id}</b></small>".html_safe
  end
  column(
    :category_type_id, header: 'Category', align: :right, html: true, mandatory: true,
                       order: proc { |scope| scope.sort { |a, b| a.category_type.code <=> b.category_type.code } }
  ) do |asset|
    "<small>#{asset.category_type.code} - <b>#{asset.category_type_id}</b></small>".html_safe
  end

  column(:timing, header: 'Base time', align: :right, html: true, mandatory: true, order: false) do |asset|
    Timing.new(minutes: asset.minutes, seconds: asset.seconds, hundredths: asset.hundredths)
  end

  actions_column(edit: true, destroy: true, mandatory: true)
end
