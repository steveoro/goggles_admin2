# frozen_string_literal: true

require 'rails_helper'

module Parser
  RSpec.describe EventType, type: :strategy do
    describe 'self.from_l2_result' do
      let(:fixture_season_id) { [182, 192, 202, 212].sample }
      let(:event_titles) { YAML.load_file(Rails.root.join("spec/fixtures/parser/event_titles-#{fixture_season_id}.yml")) }
      let(:fixture_season) { GogglesDb::Season.find(fixture_season_id) }

      describe 'with valid parameters,' do
        it 'returns both the corresponding EventType and CategoryType rows for the specified text' do
          event_titles.sample(10).each do |section_title|
            # DEBUG
            # puts "Parsing '#{section_title}'"
            event_type, category_type = described_class.from_l2_result(section_title, nil, fixture_season)
            expect(event_type).to be_a(GogglesDb::EventType) && be_valid
            expect(category_type).to be_a(GogglesDb::CategoryType) && be_valid
          end
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
