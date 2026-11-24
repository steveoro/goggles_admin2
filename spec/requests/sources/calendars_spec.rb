# frozen_string_literal: true

require 'rails_helper'

# Calendars tab and the meeting selection page (ported from the former Pull page specs).
RSpec.describe 'Sources calendars' do
  include_context 'with a Sources data root'

  let(:csv_path) { data_root.join('calendar.new', '9999', 'test-cal.csv') }

  def html = response.parsed_body

  before(:each) do
    FileUtils.mkdir_p(csv_path.dirname)
    FileUtils.cp(file_fixture('files/calendar_sample.csv'), csv_path)
  end

  describe 'GET /sources/calendars' do
    it 'groups the originals, the -sel- subsets, the -skip leftovers and the crawled files' do
      write_data('calendar.new/242/cal.csv', File.read(csv_path))
      write_data('calendar.new/242/cal-sel-20261124-101010-123.csv', File.read(csv_path))
      write_data('calendar.new/242/cal-skip.csv', File.read(csv_path))
      write_data('calendar.done/242/old.csv', File.read(csv_path))
      get(sources_calendars_path(season_id: 242))
      expect(response).to have_http_status(:success)
      expect(html.css('#sources-calendars-originals-table tr[data-sources-file]').pluck('data-sources-file')).to eq(['cal.csv'])
      expect(html.css('#sources-calendars-subsets-table tr[data-sources-file]').pluck('data-sources-file')).to eq(['cal-sel-20261124-101010-123.csv'])
      expect(html.css('#sources-calendars-leftovers-table tr[data-sources-file]').pluck('data-sources-file')).to eq(['cal-skip.csv'])
      expect(html.css('#sources-calendars-done-table tr[data-sources-file]').pluck('data-sources-file')).to eq(['old.csv'])
      original = html.at_css('#sources-calendars-originals-table tr[data-sources-file="cal.csv"]')
      expect(original.text).to include(I18n.t('sources.calendars.badges.rows', count: 10))
      expect(original.at_css('a.btn')['href']).to eq(sources_calendar_meetings_path(path: 'calendar.new/242/cal.csv'))
      expect(original.at_css("form[action='#{sources_crawls_path}'] input[name='kind']")['value']).to eq('calendar_results')
    end
  end

  describe 'GET /sources/calendars/meetings' do
    it 'renders one row per CSV meeting with its state indicators' do
      get(sources_calendar_meetings_path(path: csv_path.to_s))
      expect(response).to have_http_status(:success)
      expect(response.body).to include('Distanze Speciali Campania', '7° Trofeo Gonzaga - Memorial Rascaroli')
      # 10 CSV rows => 10 checkboxes (some disabled):
      expect(response.body.scan('selected_rows[]').size).to eq(10)
      form = html.at_css('form#frm-selected-meetings')
      expect(form['action']).to eq(sources_crawls_path)
      expect(form.at_css('input[name="file_path"]')['value']).to eq('calendar.new/9999/test-cal.csv')
      expect(form.at_css('input[name="rows_count"]')['value']).to eq('10')
    end

    it 'marks a row as pending when its manifest sits in manifests/<season>' do
      write_data('manifests/9999/manifest-2026-10-24-Distanze_Speciali_Campania.pdf', 'x')
      get(sources_calendar_meetings_path(path: csv_path.to_s))
      expect(html.at_css('.sources-manifest-pending')).to be_present
      expect(html.at_css('#sources-calendar-manifests').text).to include(I18n.t('sources.calendars.pending_manifests', count: 1))
    end

    it 'redirects with a warning for files outside crawler/data' do
      get(sources_calendar_meetings_path(path: '/etc/passwd'))
      expect(response).to redirect_to(sources_calendars_path(season_id: SeasonDefaults.default_season_id))
      expect(flash[:warning]).to eq(I18n.t('data_import.selection.errors.invalid_calendar_file'))
    end

    it 'rejects a symlinked CSV pointing outside the data root' do
      outside = sources_base_dir.join('outside.csv')
      FileUtils.cp(file_fixture('files/calendar_sample.csv'), outside)
      File.symlink(outside, csv_path.dirname.join('linked.csv'))
      get(sources_calendar_meetings_path(path: csv_path.dirname.join('linked.csv').to_s))
      expect(response).to have_http_status(:see_other)
      expect(flash[:warning]).to eq(I18n.t('data_import.selection.errors.invalid_calendar_file'))
    end

    it 'rejects calendar files already moved to calendar.done' do
      done = write_data('calendar.done/9999/test-cal.csv', File.read(csv_path))
      get(sources_calendar_meetings_path(path: done.to_s))
      expect(response).to have_http_status(:see_other)
      expect(flash[:warning]).to be_present
    end

    it 'does not render non-http meeting URLs as links' do
      File.write(csv_path, "startURL,date,isCancelled,name,place,meetingUrl,year\r\n\"\",\"24/10\",,\"Evil\",\"X\",\"javascript:alert(1)\",2026\r\n")
      get(sources_calendar_meetings_path(path: csv_path.to_s))
      expect(response).to have_http_status(:success)
      expect(response.body).not_to include('href="javascript:')
    end
  end
end
