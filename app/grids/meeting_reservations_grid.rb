# frozen_string_literal: true

# = MeetingReservationsGrid
#
# DataGrid used to manage GogglesDb::MeetingReservation rows.
#
class MeetingReservationsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:meeting_id, :integer)
  filter(:team_id, :integer)
  filter(:swimmer_id, :integer)
  filter(:badge_id, :integer)
  filter(:not_coming, :boolean)
  filter(:confirmed, :boolean)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:meeting_id, align: :right, mandatory: true)
  column(
    :meeting_name, html: true, mandatory: true,
                   order: proc { |scope| scope.sort { |a, b| a.meeting.decorate.short_label <=> b.meeting.decorate.short_label } }
  ) do |asset|
    asset.meeting.decorate.short_label
  end
  column(:user_id, align: :right)
  column(:team_id, align: :right)
  column(:badge_id, align: :right, mandatory: true)
  column(:swimmer_id, align: :right)
  column(
    :swimmer_name, html: true, mandatory: true,
                   order: proc { |scope| scope.sort { |a, b| a.swimmer.complete_name <=> b.swimmer.complete_name } }
  ) do |asset|
    asset.swimmer.complete_name
  end
  column(:notes)
  boolean_column(:not_coming, align: :center, mandatory: true, order: false)
  boolean_column(:confirmed, align: :center, mandatory: true, order: false)

  actions_column(edit: true, destroy: true, expand: true, mandatory: true)
end
