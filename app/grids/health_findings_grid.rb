# frozen_string_literal: true

#
# = HealthFindingsGrid
#
# DataGrid of the data health findings of one season section (Ops::HealthFinding, local ops DB; see
# Health::SectionsController), unlike the API-domain grids: its scope is a real relation, narrowed by the controller
# to the season and the check (<tt>HealthFindingsGrid.new(params) { |scope| scope.for_season(id).for_check(key) }</tt>).
#
# Filters: status (default 'open'; 'visible' = every status but resolved), severity, free text (title or subject id).
# The selection column feeds the bulk form of the section (checkboxes bound to it through their 'form' attribute).
# Headers & filter labels: 'datagrid.health_findings_grid.*' (config/locales/health.*.yml).
#
class HealthFindingsGrid < BaseGrid
  self.cached = false

  STATUS_FILTERS = (%w[visible] + Ops::HealthFinding::STATUSES).freeze
  PER_PAGE = 50

  scope { Ops::HealthFinding.by_severity }

  filter(:status, :enum, select: -> { STATUS_FILTERS.map { |s| [I18n.t("health.section.status_filters.#{s}"), s] } },
                         default: 'open', include_blank: false) do |value, scope|
    value == 'visible' ? scope.visible : scope.where(status: value)
  end
  filter(:severity, :enum, select: -> { Ops::HealthFinding::SEVERITIES.map { |s| [I18n.t("health.severities.#{s}"), s] } })
  filter(:search, :string) do |value, scope|
    text = value.to_s.strip
    next scope if text.blank?

    like = "%#{Ops::HealthFinding.sanitize_sql_like(text)}%"
    scope.where('title LIKE ? OR subject_ids LIKE ? OR CAST(subject_id AS TEXT) = ?', like, like, text)
  end

  # (checkbox bound to the section bulk form, see Health::SectionsController)
  column(:selected, html: true, order: false, header: '') do |row|
    check_box_tag('ids[]', row.id, false, id: "health-finding-#{row.id}", class: 'form-check-input health-finding-select',
                                          form: "health-bulk-#{row.check_key.parameterize}",
                                          'aria-label' => I18n.t('health.section.select_row', id: row.id))
  end
  column(:subject, html: true, order: false) do |row|
    label = row.subject_ids.present? ? row.subject_ids.tr(',', ', ') : row.subject_id.to_s
    content_tag(:span, "#{I18n.t("health.subjects.#{row.subject_type}", default: row.subject_type.to_s)} #{label}",
                class: 'text-nowrap small font-monospace')
  end
  column(:title, html: true, order: false) do |row|
    link_to(row.display_title, health_finding_path(row), data: { turbo_frame: '_top' })
  end
  column(:severity, html: true, order: false) do |row|
    render(Health::BadgeComponent.new(kind: :severity, value: row.severity))
  end
  column(:status, html: true, order: false) do |row|
    badge = render(Health::BadgeComponent.new(kind: :status, value: row.status))
    next badge if row.note.blank?

    safe_join([badge, ' ', content_tag(:i, '', class: 'fa-solid fa-note-sticky text-body-secondary', title: row.note,
                                               'aria-label' => row.note, role: 'img')])
  end
  column(:last_seen_at, html: true, order: false) do |row|
    row.last_seen_at ? content_tag(:span, I18n.l(row.last_seen_at.localtime, format: :short), class: 'small text-nowrap') : '-'
  end
  column(:finding_actions, html: true, order: false, header: '') do |row|
    render(Health::FindingActionsComponent.new(finding: row, compact: true))
  end
end
