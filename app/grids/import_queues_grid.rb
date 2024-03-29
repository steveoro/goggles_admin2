# frozen_string_literal: true

# = ImportQueuesGrid
#
# DataGrid used to manage GogglesDb::ImportQueue rows.
#
class ImportQueuesGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  decorate { |row| GogglesDb::ImportQueueDecorator.new(row) }

  filter(:user_id, :integer)
  filter(:done, :boolean)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:state_flag, align: :center, html: true, mandatory: true)
  column(:user_id, align: :right, mandatory: true)
  column(:text_label, align: :center, html: true, mandatory: true)
  column(:process_runs, align: :right, mandatory: true)
  column(:request_data)
  column(:solved_data)
  boolean_column(:done, align: :center, mandatory: true, order: false)
  column(:uid)
  column(:bindings_left_count, header: 'Bindings left', align: :right, mandatory: true)
  column(:bindings_left_list)
  column(:error_messages)
  column(:import_queue_id)
  column(:created_at)
  actions_column(edit: true, destroy: true, mandatory: true)
end
