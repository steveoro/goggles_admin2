# frozen_string_literal: true

# = MeetingEventReservationsGrid
#
# DataGrid used to manage GogglesDb::MeetingEventReservation rows.
#
class MeetingEventReservationsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:id, :integer)
  filter(:name, :string, header: 'Name (~)') { |_value, scope| scope }

  column(:id, align: :right, mandatory: true)
  column(:meeting_reservation_id, align: :right)
  column(:meeting_id, align: :right)
  column(:team_id, align: :right)
  column(:swimmer_id, align: :right)
  column(:badge_id, align: :right)
  column(:meeting_event_id, align: :right)
  column(
    :meeting_event_name, header: 'Event', html: true, mandatory: true,
                         order: proc { |scope| scope.sort { |a, b| a.meeting_event.decorate.display_label <=> b.meeting_event.decorate.display_label } }
  ) do |asset|
    asset.meeting_event.decorate.display_label
  end
  column(:minutes, align: :right, mandatory: true, order: false)
  column(:seconds, align: :right, mandatory: true, order: false)
  column(:hundredths, align: :right, mandatory: true, order: false)
  boolean_column(:accepted, align: :center, mandatory: true, order: false)
  actions_column(edit: 'events', destroy: false, mandatory: true)
end
