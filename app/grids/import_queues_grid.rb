# frozen_string_literal: true

# = ImportQueuesGrid
#
# DataGrid used to manage GogglesDb::ImportQueue rows.
#
# The SQL batch rows (+batch_sql+) pushed from the SQL Outbox link to their Outbox entry (by
# Ops::SqlScript#remote_iq_id): set +outbox_scripts+ (remote id => Ops::SqlScript) with the domain.
#
class ImportQueuesGrid < BaseGrid
  # { import queue id => Ops::SqlScript } for the current domain (see .outbox_scripts_for)
  class_attribute(:outbox_scripts, default: {})

  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # The Outbox scripts pushed as the given import queue rows ({ remote id => Ops::SqlScript }; {} without the ops DB).
  def self.outbox_scripts_for(rows)
    ids = Array(rows).filter_map { |row| row.id if row.respond_to?(:batch_sql) && row.batch_sql }
    return {} if ids.empty?

    Ops.safely({}) { Ops.available? ? Ops::SqlScript.where(remote_iq_id: ids).index_by(&:remote_iq_id) : {} }
  end

  decorate { |row| GogglesDb::ImportQueueDecorator.new(row) }

  filter(:user_id, :integer)
  filter(:done, :boolean)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:state_flag, align: :center, html: true, mandatory: true)
  column(:user_id, align: :right, mandatory: true)
  column(:text_label, align: :center, html: true, mandatory: true)
  column(:process_runs, align: :right, mandatory: true)
  boolean_column(:batch_sql, header: 'SQL batch', align: :center, mandatory: true, order: false)
  column(:outbox, header: 'Outbox', html: true, mandatory: true, order: false) do |asset|
    script = ImportQueuesGrid.outbox_scripts[asset.id]
    script ? link_to(script.filename, outbox_script_path(script), class: 'font-monospace small') : ''
  end
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
