# frozen_string_literal: true

#
# = FedernuotoWatchAlertComponent
#
# Sticky alert shown on any page when the FIN "Riepilogo Eventi" page has changed since it was
# last acknowledged (see FedernuotoWatch). Lists the meetings added, removed, updated or with newly
# published results, plus quick actions (pull calendar w/ crawler auto-start, check again).
#
# Rendered both by the layout (pending change from the state store) and by
# FedernuotoWatch::Notifier for live broadcasts: in the latter case there's no user session,
# so the forms are rendered *without* CSRF tokens (added client-side by the Stimulus controller).
#
class FedernuotoWatchAlertComponent < ViewComponent::Base
  # Max items shown for each list
  MAX_ITEMS = 10

  # Lists shown, in order, with their CSS class:
  SECTIONS = {
    'with_results' => 'text-success',
    'added' => 'text-primary',
    'updated' => 'text-secondary',
    'removed' => 'text-danger'
  }.freeze

  # Returns a new component for the pending change stored, if any (renders nothing otherwise).
  def self.from_store(store = FedernuotoWatch::StateStore.new)
    new(change: store.pending_change)
  end

  # == Params:
  # - change: the pending change Hash (see FedernuotoWatch::Checker); can be +nil+.
  def initialize(change:)
    super()
    @change = change.presence || {}
  end

  def render?
    @change['detected_at'].present?
  end

  protected

  # Returns the list of [key, css_class, rows] for each non-empty section.
  def sections
    SECTIONS.filter_map do |key, css_class|
      rows = Array(@change[key])
      [key, css_class, rows] if rows.any?
    end
  end

  def page_text_only_change?
    sections.empty?
  end

  def detected_at
    format_time(@change['detected_at'])
  end

  # Returns the first detection time when different from the latest one, or nil.
  def first_detected_at
    first = @change['first_detected_at']
    return if first.blank? || first == @change['detected_at']

    format_time(first)
  end

  def row_label(row)
    label = "#{row['date']} #{row['year']} · #{row['name']}"
    label += " (#{row['place']})" if row['place'].present?
    label += " – #{row['info']}" if row['info'].present?
    label
  end

  private

  def format_time(iso_time)
    local_time = FedernuotoWatch.local_time(iso_time)
    local_time ? I18n.l(local_time, format: :short) : iso_time.to_s
  end
end
