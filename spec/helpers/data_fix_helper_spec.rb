# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFixHelper do
  describe '#data_fix_card_frame_id' do
    it 'is stable for a key and differs between keys' do
      expect(helper.data_fix_card_frame_id('team', 'Team A')).to eq("team-card-k-#{Digest::SHA1.hexdigest('Team A')[0, 10]}")
      expect(helper.data_fix_card_frame_id('team', 'Team A')).to match(/\Ateam-card-k-\h{10}\z/)
      expect(helper.data_fix_card_frame_id('team', 'Team A')).not_to eq(helper.data_fix_card_frame_id('team', 'Team B'))
      expect(helper.data_fix_card_frame_id('swimmer', 'Team A')).to start_with('swimmer-card-k-')
    end
  end

  describe '#data_fix_issue_marker' do
    it 'joins the codes, or answers nil without any' do
      expect(helper.data_fix_issue_marker(%w[teams_review teams_review structure_invalid])).to eq('teams_review structure_invalid')
      expect(helper.data_fix_issue_marker([nil, ''])).to be_nil
    end
  end

  describe '#data_fix_issue_title' do
    it 'names the issues through the verdict labels' do
      expect(helper.data_fix_issue_title(%w[teams_review])).to eq(I18n.t('data_fix.verdicts.issues.teams_review'))
    end
  end
end
