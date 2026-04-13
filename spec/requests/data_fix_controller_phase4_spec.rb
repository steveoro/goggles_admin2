# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFixController do
  include AdminSignInHelpers

  describe 'Phase 4 (Events) integration' do
    let(:admin_user) { prepare_admin_user }
    let(:temp_dir) { Dir.mktmpdir }
    let(:season) { FactoryBot.create(:season) }
    let(:season_dir) { File.join(temp_dir, season.id.to_s) }
    let(:source_file) { File.join(season_dir, 'test_source.json') }
    let(:phase4_file) { source_file.sub('.json', '-phase4.json') }

    before(:each) do
      sign_in_admin(admin_user)
      FileUtils.mkdir_p(season_dir)
      File.write(source_file, JSON.pretty_generate({ 'layoutType' => 4, 'events' => [] }))

      phase4_data = {
        'sessions' => [
          {
            'session_order' => 2,
            'events' => [
              { 'key' => '100SL', 'event_order' => 1, 'session_order' => 2 },
              { 'key' => '100DO', 'event_order' => 4, 'session_order' => 2 },
              { 'key' => '50RA', 'event_order' => 2, 'session_order' => 2 },
              { 'key' => '100MI', 'event_order' => 3, 'session_order' => 2 }
            ]
          },
          {
            'session_order' => 1,
            'events' => [
              { 'key' => '400SL', 'event_order' => 1, 'session_order' => 1 }
            ]
          }
        ]
      }
      PhaseFileManager.new(phase4_file).write!(data: phase4_data, meta: { 'generator' => 'test' })
    end

    after(:each) do
      FileUtils.rm_rf(temp_dir) if File.directory?(temp_dir)
    end

    it 'updates event_order on the intended event using rendered form indexes' do
      get review_events_path(file_path: source_file, phase4_v2: 1)
      expect(response).to be_successful

      doc = Nokogiri::HTML(response.body)
      target_card = doc.css('div[id^="event-card-"]').find { |node| node.text.include?('100DO') }

      expect(target_card).to be_present
      rendered_session_index = target_card.at_css('input[name="session_index"]')['value']
      rendered_event_index = target_card.at_css('input[name="event_index"]')['value']

      expect(rendered_session_index).to eq('0')
      expect(rendered_event_index).to eq('1')

      patch update_phase4_event_path,
            params: {
              file_path: source_file,
              session_index: rendered_session_index,
              event_index: rendered_event_index,
              target_session_order: 2,
              event: { event_order: '3', autofilled: '1' }
            }

      expect(response).to redirect_to(review_events_path(file_path: source_file, phase4_v2: 1))

      updated_data = PhaseFileManager.new(phase4_file).data
      updated_event = updated_data.fetch('sessions').find { |s| s['session_order'] == 2 }
                                  .fetch('events').find { |e| e['key'] == '100DO' }
      expect(updated_event['event_order']).to eq(3)
    end

    it 'deletes the intended event using rendered form indexes' do
      get review_events_path(file_path: source_file, phase4_v2: 1)
      expect(response).to be_successful

      doc = Nokogiri::HTML(response.body)
      target_card = doc.css('div[id^="event-card-"]').find { |node| node.text.include?('50RA') }

      expect(target_card).to be_present
      rendered_session_index = target_card.at_css('input[name="session_index"]')['value']
      rendered_event_index = target_card.at_css('input[name="event_index"]')['value']

      expect(rendered_session_index).to eq('0')
      expect(rendered_event_index).to eq('2')

      delete data_fix_delete_event_path,
             params: {
               file_path: source_file,
               session_index: rendered_session_index,
               event_index: rendered_event_index
             }

      expect(response).to redirect_to(review_events_path(file_path: source_file, phase4_v2: 1))

      updated_events = PhaseFileManager.new(phase4_file).data.fetch('sessions')
                                       .find { |s| s['session_order'] == 2 }
                                       .fetch('events')
      expect(updated_events.any? { |e| e['key'] == '50RA' }).to be(false)
      expect(updated_events.any? { |e| e['key'] == '100DO' }).to be(true)
    end
  end
end
