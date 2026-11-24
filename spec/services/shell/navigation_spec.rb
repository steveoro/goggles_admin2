# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Shell::Navigation do
  # GET routes of app controllers that are not pages of their own (JSON/turbo-stream endpoints, frames,
  # the sign-in page outside the shell), as 'controller#action':
  let(:non_page_routes) do
    %w[
      users/sessions#new
      lookup#index lookup#show
      pull#extraction_status pull#edit_name pull#edit_file
      shell/status#show
    ]
  end

  # 'controller#action' of every GET route served by a controller under app/controllers.
  let(:app_get_routes) do
    Rails.application.routes.routes.filter_map do |route|
      next unless route.verb.to_s.split('|').include?('GET')

      controller = route.defaults[:controller]
      action = route.defaults[:action]
      next if controller.blank? || action.blank?

      file = Rails.root.join('app/controllers', "#{controller}_controller.rb")
      "#{controller}##{action}" if file.exist?
    end.uniq
  end

  describe 'ITEMS' do
    it 'has unique keys and only known groups' do
      keys = described_class::ITEMS.map(&:key)
      expect(keys).to eq(keys.uniq)
      expect(described_class::ITEMS.map(&:group).uniq - described_class::GROUPS).to be_empty
    end

    it 'resolves each path to a GET route whose controller matches one of the item match entries' do
      described_class::ITEMS.each do |item|
        path = described_class.path_for(item)
        recognized = Rails.application.routes.recognize_path(path.split('?').first, method: :get)
        match_controllers = item.match.map { |entry| entry.split(/[#?]/).first }
        # (The contextual Data-Fix item lands on its parent page, Result files)
        expected = item.sidebar? ? match_controllers : described_class.find(item.parent).match.map { |e| e.split(/[#?]/).first }
        expect(expected).to include(recognized[:controller]), "#{item.key}: #{path} => #{recognized.inspect}"
      end
    end

    it 'maps each sidebar item path back to the item itself' do
      described_class::ITEMS.select(&:sidebar?).each do |item|
        path = described_class.path_for(item)
        recognized = Rails.application.routes.recognize_path(path.split('?').first, method: :get)
        query = Rack::Utils.parse_query(URI(path).query.to_s)
        expect(described_class.item_for(recognized[:controller], recognized[:action], query)).to eq(item), item.key.to_s
      end
    end

    it 'has every label key in both en and it (app or engine locales)' do
      labels = described_class::ITEMS.map(&:label_key) + described_class::GROUPS.map { |group| "shell.groups.#{group}" }
      locales = %i[en it]
      labels.each do |label_key|
        locales.each do |locale|
          expect(I18n.t(label_key, locale:, default: nil)).to be_a(String), "missing #{locale}: #{label_key}"
        end
      end
    end

    it 'uses Font Awesome 6 icon names available in the vendored stylesheet' do
      css = Rails.root.join('vendor/assets/stylesheets/fontawesome/css/all.min.css').read
      described_class::ITEMS.map(&:icon).uniq.each do |icon|
        expect(css).to match(/\.#{Regexp.escape(icon)}[{,]/), icon
      end
    end
  end

  describe '.item_for' do
    it 'maps every HTML GET route of an app controller to an item (except the declared non-page routes)' do
      unmapped = (app_get_routes - non_page_routes).reject do |route|
        controller, action = route.split('#')
        described_class.item_for(controller, action, {})
      end
      expect(unmapped).to be_empty, "routes without a navigation item: #{unmapped.inspect}"
    end

    it 'declares only existing routes as non-page routes' do
      expect(non_page_routes - app_get_routes).to be_empty
    end

    it 'prefers the most specific match (PDFs tab vs. Result files)' do
      expect(described_class.item_for('pull', 'result_files', { 'parent_folder' => 'pdfs' }).key).to eq(:pdfs)
      expect(described_class.item_for('pull', 'result_files', ActionController::Parameters.new(parent_folder: 'pdfs')).key).to eq(:pdfs)
      expect(described_class.item_for('pull', 'result_files', {}).key).to eq(:result_files)
      expect(described_class.item_for('pull', 'result_files', { parent_folder: 'results.new' }).key).to eq(:result_files)
      expect(described_class.item_for('pdf', 'extract_txt', {}).key).to eq(:pdfs)
    end

    it 'maps contextual children to their parent controller item' do
      expect(described_class.item_for('api_meetings', 'no_mirs').key).to eq(:meetings)
      expect(described_class.item_for('api_meeting_reservations', 'expand').key).to eq(:reservations)
      expect(described_class.item_for('data_fix/teams', 'review_teams').key).to eq(:data_fix)
      expect(described_class.item_for('best_results', 'best_in_5y').key).to eq(:best_in_5y)
    end

    it 'maps the data health pages and frames to the Data quality > Data health item' do
      %w[health#index health#matrix health/seasons#show health/seasons#summary health/sections#show
         health/findings#show].each do |route|
        controller, action = route.split('#')
        item = described_class.item_for(controller, action)
        expect(item&.key).to eq(:health), route
        expect(item.group).to eq(:data_quality)
      end
    end

    it 'maps the operations pages and the run pages to the Data quality > Operations item' do
      %w[operations#index operations#new maintenance/runs#show maintenance/runs#status maintenance/runs#create].each do |route|
        controller, action = route.split('#')
        item = described_class.item_for(controller, action)
        expect(item&.key).to eq(:operations), route
        expect(item.group).to eq(:data_quality)
      end
    end

    it 'maps the season-start checklist (phase 13) to a contextual child of Operations' do
      %w[maintenance/season_start#index maintenance/season_start#show].each do |route|
        controller, action = route.split('#')
        expect(described_class.item_for(controller, action)&.key).to eq(:season_start), route
      end
      crumbs = described_class.breadcrumbs_for('maintenance/season_start', 'show', {})
      expect(crumbs.map(&:first).first(3)).to eq([I18n.t('shell.groups.data_quality'), I18n.t('maintenance.nav'), I18n.t('maintenance.season_start.nav')])
    end

    it 'returns nil for an unknown page' do
      expect(described_class.item_for('lookup', 'index')).to be_nil
      expect(described_class.item_for('whatever', 'index')).to be_nil
    end
  end

  describe '.breadcrumbs_for' do
    it 'returns Import › Result files › Data-Fix for a Data-Fix review page' do
      crumbs = described_class.breadcrumbs_for('data_fix/teams', 'review_teams', {})
      expect(crumbs.map(&:first)).to eq(
        [I18n.t('shell.groups.import'), I18n.t('data_import.calendar.result_files_page_title'), I18n.t('shell.nav.data_fix')]
      )
      expect(crumbs.first.last).to be_nil
      expect(crumbs.second.last).to eq('/pull/result_files')
    end

    it 'adds the action as the last crumb for a contextual child page' do
      crumbs = described_class.breadcrumbs_for('api_meetings', 'no_mirs', {})
      expect(crumbs.map(&:first)).to eq(
        [I18n.t('shell.groups.entities'), I18n.t('dashboard.meetings.title'), I18n.t('shell.actions.no_mirs')]
      )
    end

    it 'returns group › item for a landing page' do
      expect(described_class.breadcrumbs_for('settings', 'index', {}))
        .to eq([[I18n.t('shell.groups.system'), nil], [I18n.t('dashboard.settings.title'), '/settings']])
    end

    it 'is empty for a page without item' do
      expect(described_class.breadcrumbs_for('lookup', 'index', {})).to eq([])
    end
  end

  describe '.groups' do
    it 'lists only the non-empty groups, in order, with sidebar items only' do
      groups = described_class.groups
      expect(groups.map(&:key)).to eq(%i[dashboard import data_quality entities reports support system])
      expect(groups.flat_map(&:items)).to all(be_sidebar)
      expect(groups.flat_map(&:items).map(&:key)).not_to include(:data_fix)
    end

    it 'disables the items not reachable from an API-offline session' do
      online = described_class.groups(offline: false)
      offline = described_class.groups(offline: true)
      expect(online.flat_map { |group| group.items.select { |item| group.disabled?(item) } }).to be_empty
      enabled_offline = offline.flat_map { |group| group.items.reject { |item| group.disabled?(item) } }
      # (07: the Outbox page reads only the local files and the ops DB; its push confirmation is not allowed offline)
      # (08: the DB sync page reads only the ops DB)
      expect(enabled_offline.map(&:key)).to contain_exactly(:dashboard, :settings, :remote_writes, :outbox, :db_sync)
    end
  end

  describe '.palette_entries' do
    it 'returns one entry per sidebar item with a label and a path' do
      entries = described_class.palette_entries
      expect(entries.size).to eq(described_class::ITEMS.count(&:sidebar?))
      expect(entries).to all(include(:key, :label, :path))
    end
  end
end
