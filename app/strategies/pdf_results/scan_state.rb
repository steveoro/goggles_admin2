# frozen_string_literal: true

require 'digest'

module PdfResults
  #
  # = PdfResults::ScanState
  #
  # The last scan of a results PDF, stored in the ops DB (Ops::Snapshot 'pdf_scan:<sha1 of the PDF path>', never in
  # Rails.cache): queued by Sources::PdfsController, then running / done / failed as PdfScanJob goes, with the scan
  # outcome (ScanRunner::Result: the checked formats, page count, last parsed page, format found, JSON path, log path).
  #
  # Without the ops DB nothing is stored (the scan still runs; the page shows no result).
  #
  class ScanState
    KEY_PREFIX = 'pdf_scan:'
    STATUSES = %w[queued running done failed].freeze
    # A queued or running scan older than this is considered dead (a killed worker): it no longer blocks a new one.
    STALE_AFTER = 3.hours

    attr_reader :payload, :taken_at

    def self.key(pdf_path) = "#{KEY_PREFIX}#{Digest::SHA1.hexdigest(pdf_path.to_s)}"

    # The stored state of the PDF (a ScanState), or nil.
    def self.read(pdf_path)
      row = Ops.safely { Ops.available? ? Ops::Snapshot.read(key(pdf_path)) : nil }
      row&.payload.is_a?(Hash) ? new(row.payload, taken_at: row.taken_at) : nil
    end

    # Records a queued scan (with its options).
    def self.queue!(pdf_path, options = {})
      write!(pdf_path, 'status' => 'queued', 'queued_at' => Time.current.iso8601, 'options' => options.stringify_keys)
    end

    def self.start!(pdf_path, options = {})
      previous = read(pdf_path)&.payload || {}
      write!(pdf_path, previous.slice('queued_at').merge('status' => 'running', 'started_at' => Time.current.iso8601,
                                                         'options' => options.stringify_keys))
    end

    # Stores the outcome (a ScanRunner::Result).
    def self.finish!(pdf_path, result)
      update!(pdf_path, 'status' => 'done', 'finished_at' => Time.current.iso8601, 'error' => nil,
                        'checked_formats' => plain(result.checked_formats), 'page_count' => result.page_count,
                        'last_index' => result.last_index, 'result_format_type' => result.result_format_type,
                        'last_valid_scan' => plain(result.last_valid_scan), 'json_path' => result.json_path,
                        'log_path' => result.log_path, 'txt_path' => result.txt_path, 'season_id' => result.season_id)
    end

    def self.fail!(pdf_path, message, log_path: nil)
      update!(pdf_path, 'status' => 'failed', 'finished_at' => Time.current.iso8601, 'error' => message.to_s.truncate(500),
                        'log_path' => log_path)
    end

    def self.update!(pdf_path, attributes)
      write!(pdf_path, (read(pdf_path)&.payload || {}).merge(attributes))
    end
    private_class_method :update!

    def self.write!(pdf_path, payload)
      Ops.safely { Ops::Snapshot.write!(key(pdf_path), payload.merge('pdf_path' => pdf_path.to_s), source: 'PdfScanJob') if Ops.available? }
    end
    private_class_method :write!

    # JSON-native copy (String keys) of a parser Hash.
    def self.plain(value)
      JSON.parse(value.to_h.to_json)
    end
    private_class_method :plain

    def initialize(payload, taken_at: nil)
      @payload = payload
      @taken_at = taken_at
    end

    def status = payload['status'].to_s

    STATUSES.each { |name| define_method(:"#{name}?") { status == name } }

    # Queued or running, and not stale.
    def pending?
      return false unless queued? || running?

      since = time(running? ? 'started_at' : 'queued_at') || taken_at
      since.present? && since > STALE_AFTER.ago
    end

    def stale? = (queued? || running?) && !pending?

    def full_parse? = done? && result_format_type.present? && last_index.to_i >= page_count.to_i

    def result_format_type = payload['result_format_type'].presence
    def page_count = payload['page_count'].to_i
    def last_index = payload['last_index'].to_i
    def checked_formats = payload['checked_formats'].is_a?(Hash) ? payload['checked_formats'] : {}
    def last_valid_scan = payload['last_valid_scan'].is_a?(Hash) ? payload['last_valid_scan'] : {}
    def json_path = payload['json_path'].presence
    def log_path = payload['log_path'].presence
    def error = payload['error'].presence
    def options = payload['options'].is_a?(Hash) ? payload['options'] : {}

    def queued_at = time('queued_at')
    def started_at = time('started_at')
    def finished_at = time('finished_at')

    # Full status text ("Parsed: 3-finlazio, 12/12 pages", "No format matched at page 3 of 12", ...).
    def label
      return I18n.t('sources.pdfs.scan.states.stale') if stale?
      return I18n.t("sources.pdfs.scan.states.#{status}") if queued? || running?
      return I18n.t('sources.pdfs.scan.states.failed_with', error: error.to_s.truncate(120)) if failed?
      return I18n.t('sources.pdfs.scan.states.parsed', family: result_format_type, count: page_count) if full_parse?

      I18n.t('sources.pdfs.scan.states.stopped', page: last_index + 1, count: page_count)
    end

    # Badge text of the PDFs tab.
    def short_label
      return I18n.t('sources.pdfs.scan.badges.parsed') if full_parse?
      return I18n.t('sources.pdfs.scan.badges.stopped') if done?

      I18n.t("sources.pdfs.scan.badges.#{stale? ? 'stale' : status}")
    end

    # Bootstrap tone of the badge.
    def tone
      return 'success' if full_parse?
      return 'info' if pending?

      done? ? 'warning' : 'danger'
    end

    private

    def time(key)
      value = payload[key]
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end
  end
end
