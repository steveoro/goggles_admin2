# frozen_string_literal: true

#
# = OperationRunsGrid
#
# DataGrid of the maintenance operation runs (Ops::OperationRun, local ops DB; see OperationsController#index), newest
# first. Filters: operation, mode, status, season. Headers & filter labels: 'datagrid.operation_runs_grid.*'
# (config/locales/maintenance.*.yml).
#
class OperationRunsGrid < BaseGrid
  self.cached = false

  scope { Ops::OperationRun.recent }

  filter(:operation_key, :enum, select: -> { Maintenance::Registry.all.map { |klass| [klass.title, klass.key] } })
  filter(:mode, :enum, select: -> { Ops::OperationRun::MODES.map { |mode| [I18n.t("maintenance.modes.#{mode}"), mode] } })
  filter(:status, :enum, select: -> { Ops::OperationRun::STATUSES.map { |status| [I18n.t("maintenance.statuses.#{status}"), status] } })
  filter(:season_id, :integer)

  column(:id, html: true, order: false) do |row|
    link_to("##{row.id}", maintenance_run_path(row), data: { turbo_frame: '_top' })
  end
  column(:created_at, html: true, order: false) do |row|
    content_tag(:span, I18n.l(row.created_at.localtime, format: :short), class: 'small text-nowrap')
  end
  column(:operation, html: true, order: false) do |row|
    content_tag(:code, row.operation_key, class: 'small')
  end
  column(:mode, html: true, order: false) do |row|
    content_tag(:span, I18n.t("maintenance.modes.#{row.mode}", default: row.mode), class: "badge #{Maintenance::PlanReportComponent.mode_css(row.mode)}")
  end
  # ('interrupted' for a queued/running run no worker will finish, see Ops::OperationRun#interrupted?)
  column(:status, html: true, order: false) do |row|
    status = row.display_status
    content_tag(:span, I18n.t("maintenance.statuses.#{status}", default: status),
                class: "badge #{Maintenance::PlanReportComponent.status_css(status)}", data: { operation_status: status })
  end
  column(:label, html: true, order: false) do |row|
    link_to(row.display_label, maintenance_run_path(row), data: { turbo_frame: '_top' })
  end
  column(:season_id, order: false)
  column(:script, html: true, order: false) do |row|
    filename = row.summary_hash['sql_filename']
    filename.present? ? link_to(filename, outbox_path(focus: filename), class: 'small font-monospace') : '-'
  end
  column(:origin, order: false) do |row|
    I18n.t("maintenance.origins.#{row.origin}", default: row.origin)
  end
end
