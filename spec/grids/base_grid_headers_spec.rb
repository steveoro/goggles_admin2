# frozen_string_literal: true

require 'rails_helper'

# (phase 15) Grid headers come from config/locales/grids.{en,it}.yml (BaseGrid.column_header / .filter_header).
RSpec.describe BaseGrid do
  let(:grid_classes) do
    Rails.root.glob('app/grids/*_grid.rb').map { |file| File.basename(file, '.rb').camelize.constantize } - [described_class]
  end

  # [grid, name, filter?] of every column and filter, minus the explicitly empty headers (e.g. a checkbox column)
  let(:headers) do
    grid_classes.flat_map do |grid|
      grid.columns.reject { |column| column.options[:header] == '' }.map { |column| [grid, column, false] } +
        grid.filters.map { |filter| [grid, filter, true] }
    end
  end

  it 'has no text header written in a grid file (every header is a locale key)' do
    literal = headers.select { |_grid, definition, _filter| definition.options[:header].is_a?(String) }
    expect(literal.map { |grid, definition, _filter| "#{grid.name}##{definition.name}" }).to eq([])
  end

  it 'finds a grids.* key for every column header and filter label, in en and it' do
    locales = %i[en it]
    missing = headers.flat_map do |grid, definition, filter|
      keys = grid.header_keys(definition.name, filter:)
      locales.reject { |locale| keys.any? { |key| I18n.exists?(key, locale) } }
             .map { |locale| "#{locale}: #{grid.name}##{definition.name} (#{keys.join(' | ')})" }
    end
    expect(missing).to eq([])
  end

  it 'reads the headers in the current locale, at render time' do
    column = TeamsGrid.column_by_name(:editable_name)
    expect(I18n.with_locale(:en) { column.header }).to eq('Editable name')
    expect(I18n.with_locale(:it) { column.header }).to eq('Nome modificabile')
  end

  it 'falls back from a filter label to the column of the same name, then to grids.defaults' do
    expect(I18n.with_locale(:en) { MeetingsGrid.filter_by_name(:description).header }).to eq('Description')
    expect(I18n.with_locale(:en) { MeetingsGrid.filter_by_name(:name).header }).to eq('Name (~)')
    expect(I18n.with_locale(:it) { TeamsGrid.column_by_name(:actions).header }).to eq('Azioni')
  end

  it 'keys a grid by its class name without the Grid suffix' do
    expect(OperationRunsGrid.i18n_key).to eq('operation_runs')
    expect(MeetingEventReservationsGrid.i18n_key).to eq('meeting_event_reservations')
  end
end
