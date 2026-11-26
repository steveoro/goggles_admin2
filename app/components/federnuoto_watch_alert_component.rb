# frozen_string_literal: true

#
# = FedernuotoWatchAlertComponent
#
# Sticky alert shown on any page when the FIN "Riepilogo Eventi" page has changed since it was
# last acknowledged (see FedernuotoWatch). Lists the meetings added, removed, updated or with newly
# published results, plus quick actions (open the Season board, check again).
#
# Rendered both by the layout (pending change from the state store) and by
# FedernuotoWatch::Notifier for live broadcasts: in the latter case there's no user session,
# so the forms are rendered *without* CSRF tokens (added client-side by the Stimulus controller).
#
# 0.10.103: the dismiss posts the digest of the snapshot shown (a newer change is never acknowledged unseen), and the
# progress of the automation (FedernuotoWatch::Progress, stored by FedernuotoWatch::ParityCheck) adds what the system is
# doing about the change: the 'Eventi' calendar crawl queued or running, the meetings being crawled or prepared, the
# ones still waiting (and why), or that the automation is off. Not rendered while the automation found nothing
# actionable in the change (Progress.alert_shown?).
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

  # Pending rows listed by the progress lines.
  MAX_PENDING = 5

  # Returns a new component for the pending change stored, if any (renders nothing otherwise).
  def self.from_store(store = FedernuotoWatch::StateStore.new)
    state = store.read
    change = state['change'].presence
    progress = (FedernuotoWatch::Progress.read(state['digest']) if change.is_a?(Hash))
    new(change:, digest: state['digest'], progress:)
  end

  # == Params:
  # - change: the pending change Hash (see FedernuotoWatch::Checker); can be +nil+;
  # - digest: the snapshot digest of the change (posted by the dismiss; nil: whatever the latest is);
  # - progress: the FedernuotoWatch::Progress payload of that snapshot (or nil).
  def initialize(change:, digest: nil, progress: nil)
    super()
    @change = change.presence || {}
    @digest = digest
    @progress = progress.is_a?(Hash) ? progress : nil
  end

  def render?
    FedernuotoWatch::Progress.alert_shown?(@change, @progress)
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

  attr_reader :digest

  def progress? = !@progress.nil?
  def automation_off? = progress? && @progress['automation'] != true

  # Progress lines (Strings) of what the automation is doing (empty without a progress, or with the automation off).
  def progress_lines
    return [] if !progress? || automation_off?

    lines = []
    lines << t("federnuoto_watch.alert.progress.calendar_#{@progress['calendar']}") if %w[queued running].include?(@progress['calendar'])
    awaiting = @progress['awaiting_calendar'].to_i
    lines << t('federnuoto_watch.alert.progress.awaiting_calendar', count: awaiting) if awaiting.positive?
    lines.concat(busy_lines)
    lines
  end

  # Rows not followed up yet (Hashes: name, reason), at most MAX_PENDING.
  def waiting_rows
    pending_rows.reject { |row| BUSY_REASONS.include?(row['reason']) }
  end

  def waiting_label(row)
    t("federnuoto_watch.alert.progress.reasons.#{row['reason']}", name: row['name'], default: row['name'].to_s)
  end

  def more_waiting = [waiting_count - MAX_PENDING, 0].max

  # True for an http(s) link on the FIN site only (the page's hrefs are never rendered otherwise, 0.10.103).
  def fin_link?(url) = FINEventId.fin_url?(url)

  def row_label(row)
    label = "#{row['date']} #{row['year']} · #{row['name']}"
    label += " (#{row['place']})" if row['place'].present?
    label += " – #{row['info']}" if row['info'].present?
    label
  end

  private

  # Reasons of a row a job works on right now (counted, not listed).
  BUSY_REASONS = %w[crawling extracting preparing busy].freeze
  private_constant :BUSY_REASONS

  def pending_rows
    Array(@progress&.dig('pending')).grep(Hash)
  end

  def waiting_count
    pending_rows.count { |row| BUSY_REASONS.exclude?(row['reason']) }
  end

  # "2 meetings being crawled", "1 meeting being prepared"...
  def busy_lines
    counts = pending_rows.pluck('reason').tally
    BUSY_REASONS.filter_map do |reason|
      count = counts[reason].to_i
      t("federnuoto_watch.alert.progress.busy.#{reason}", count:) if count.positive?
    end
  end

  def format_time(iso_time)
    local_time = FedernuotoWatch.local_time(iso_time)
    local_time ? I18n.l(local_time, format: :short) : iso_time.to_s
  end
end
