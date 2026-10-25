# frozen_string_literal: true

require 'csv'

module CrawlerCalendar
  # = CrawlerCalendar::Sheet
  #
  #   - version:  7-0.10.63
  #   - author:   Devin
  #
  # Loads a FIN calendar CSV file (crawler/data/calendar.new|done/<season>/*.csv)
  # and exposes its rows as CrawlerCalendar::Row objects, so the UI can show
  # per-meeting URL/manifest/source state before launching the results crawler.
  #
  # #write_subset generates a bespoke CSV containing only the selected rows —
  # same headers, verbatim field values — that the results crawler can consume
  # with zero changes on the Node side. Written next to the source file, the
  # subset inherits the consume lifecycle (moved to calendar.done once crawled,
  # leftovers appended as a -skip.csv sibling).
  #
  class Sheet
    attr_reader :file_path, :season_id, :headers, :rows

    def initialize(file_path, season_id:, data_root: Rails.root.join('crawler/data'))
      @file_path = file_path.to_s
      @season_id = season_id
      @data_root = data_root
      table = CSV.parse(File.read(@file_path), headers: true)
      @headers = table.headers
      @table = table
      @rows = table.each_with_index.map do |csv_row, index|
        Row.new(csv_row: csv_row, index: index, season_id: season_id, data_root: data_root)
      end
    end

    def row_count
      @rows.size
    end

    # Serializes the given row indexes as a new calendar CSV under the same
    # folder as the source file. Returns the destination path.
    #
    # File name: '<source base>-sel-<YYYYMMDD-HHMMSS-msec>.csv'
    def write_subset(indexes)
      dest = File.join(File.dirname(@file_path), "#{File.basename(@file_path, '.csv')}-sel-#{timestamp_suffix}.csv")
      File.write(dest, subset_csv(indexes))
      dest
    end

    # CSV text with the original headers and only the selected rows' verbatim
    # field values (round-trip safe for the crawler's csv-parser reader).
    # Same CRLF row separator used by CrawlUtil.writeCSVData.
    def subset_csv(indexes)
      CSV.generate(row_sep: "\r\n") do |csv|
        csv << @headers
        indexes.map(&:to_i).grep(0...@table.size).sort.uniq.each do |idx|
          csv << @table[idx].fields
        end
      end
    end

    private

    def timestamp_suffix
      Time.current.strftime('%Y%m%d-%H%M%S-%3N')
    end
  end
end
