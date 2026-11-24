# frozen_string_literal: true

#
# = RemoteWritesGrid
#
# Read-only DataGrid of the logged remote writes (Ops::RemoteWrite, local ops DB; see RemoteWritesController).
# Newest first; filters on endpoint (contains), outcome, HTTP method and API base URL.
# Headers & filter labels: 'grids.remote_writes.*' (config/locales/grids.*.yml).
#
class RemoteWritesGrid < BaseGrid
  STATUS_BADGES = { 'success' => 'text-bg-success', 'failed' => 'text-bg-danger', 'unreachable' => 'text-bg-secondary' }.freeze
  HTTP_METHODS = %w[post put patch delete].freeze

  scope { Ops::RemoteWrite.recent }

  filter(:endpoint, :string) { |value, scope| scope.endpoint_like(value) }
  filter(:status, :enum, select: -> { Ops::RemoteWrite::STATUSES.map { |s| [I18n.t("remote_writes.statuses.#{s}"), s] } }) do |value, scope|
    scope.with_status(value)
  end
  filter(:http_method, :enum, select: -> { HTTP_METHODS.map { |m| [m.upcase, m] } })
  filter(:base_url, :enum, select: -> { Ops::RemoteWrite.distinct.order(:base_url).pluck(:base_url) })

  column(:created_at) do |row|
    format(row.created_at) { |value| I18n.l(value.localtime, format: :short) }
  end
  column(:http_method) { |row| row.http_method.to_s.upcase }
  column(:endpoint)
  column(:status, order: false) do |row|
    format(row.status) do |value|
      content_tag(:span, I18n.t("remote_writes.statuses.#{value}"), class: "badge #{STATUS_BADGES[value]}")
    end
  end
  column(:status_code, align: :right)
  column(:payload_keys, order: false) { |row| Array(row.payload_keys).join(', ') }
  column(:error_detail, order: false)
  column(:source)
  column(:user_id, align: :right)
  column(:base_url)
end
