# frozen_string_literal: true

require 'digest'

module FedernuotoWatch
  #
  # = FedernuotoWatch::Extractor
  #
  # Extracts a normalized snapshot from the watched page HTML:
  #
  # - rows:   one Hash for each meeting row found in the yearly 'table.records.ris-style' tables, with keys
  #           'key', 'year', 'date', 'name', 'place', 'url' (results link, when present) & 'info'
  #           (any other text in the last column, e.g. a cancellation note);
  # - text:   the normalized text of 'main section#component' (scripts & styles stripped);
  # - digest: SHA256 of text + rows (so that a newly published results link is detected even
  #           when the visible text doesn't change).
  #
  class Extractor
    COMPONENT_SELECTORS = ['main section#component', 'section#component'].freeze
    TABLE_SELECTOR = 'table.records.ris-style'

    # Snapshot value object (rows are plain Hashes so that they can be serialized to JSON as-is)
    Snapshot = Data.define(:rows, :text, :digest)

    def initialize(html)
      @html = html.to_s
    end

    # Returns a Snapshot.
    # Raises FedernuotoWatch::ParseError when the component section is missing.
    def call
      component = find_component
      raise ParseError, 'section#component not found on the page' unless component

      component.css('script, style, noscript').each(&:remove)
      rows = extract_rows(component)
      text = normalize_text(component.text)
      Snapshot.new(rows:, text:, digest: compute_digest(text, rows))
    end

    # Unique key for a row (year, date, name, place)
    def self.row_key(row)
      row.values_at('year', 'date', 'name', 'place').join(' | ')
    end

    private

    def find_component
      doc = Nokogiri::HTML5(@html)
      COMPONENT_SELECTORS.lazy.map { |sel| doc.at_css(sel) }.find(&:present?)
    end

    def extract_rows(component)
      component.css(TABLE_SELECTOR).flat_map do |table|
        year = clean(table.at_css('caption')&.text)
        table.css('tr').filter_map { |tr| build_row(tr, year) }
      end
    end

    # Returns nil for header rows or rows that don't have at least (date, name, place)
    def build_row(tr_node, year)
      cells = tr_node.css('> td')
      return if cells.size < 3

      last_cell = cells.size > 3 ? cells.last : nil
      row = {
        'year' => year,
        'date' => clean(cells[0].text),
        'name' => clean(cells[1].text),
        'place' => clean(cells[2].text),
        'url' => absolute_url(last_cell&.at_css('a[href]')&.[]('href')),
        'info' => clean(last_cell&.text)
      }
      row.merge('key' => self.class.row_key(row))
    end

    def absolute_url(href)
      return '' if href.blank?

      URI.join(FedernuotoWatch::BASE_URL, href).to_s
    rescue URI::Error
      href.start_with?('http') ? href : "#{FedernuotoWatch::BASE_URL}#{href}"
    end

    # Collapses all whitespace (non-breaking spaces included) into single spaces
    def clean(text)
      text.to_s.gsub(/[[:space:]]+/, ' ').strip
    end

    # Keeps line structure while dropping blank lines & extra spacing
    def normalize_text(text)
      text.to_s.lines.map { |line| clean(line) }.compact_blank.join("\n")
    end

    def compute_digest(text, rows)
      signature = rows.map { |row| row.values_at('key', 'url', 'info').join(' | ') }
      Digest::SHA256.hexdigest([text, *signature].join("\n"))
    end
  end
end
