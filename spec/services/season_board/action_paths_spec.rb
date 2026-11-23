# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoard::ActionPaths do
  include Rails.application.routes.url_helpers

  def action(kind, **params)
    SeasonBoard::NextAction.new(kind:, params: { fin_event_id: '150091' }.merge(params))
  end

  describe '.link_path' do
    it 'opens Data-Fix step 1 for the review actions' do
      %i[review_results review_structure review_header].each do |kind|
        expect(described_class.link_path(action(kind, file_path: '/d/r.json'))).to eq(review_sessions_path(file_path: '/d/r.json', phase_v2: 1))
      end
    end

    it 'resumes the Data-Fix step of the phase (step 1 for an unknown phase)' do
      expect(described_class.link_path(action(:resume_review, file_path: '/d/p.json', phase: 3)))
        .to eq(review_swimmers_path(file_path: '/d/p.json', phase3_v2: 1))
      expect(described_class.link_path(action(:resume_review, file_path: '/d/p.json', phase: 5)))
        .to eq(review_results_path(file_path: '/d/p.json', phase5_v2: 1))
      expect(described_class.link_path(action(:resume_review, file_path: '/d/p.json', phase: 9)))
        .to eq(review_sessions_path(file_path: '/d/p.json', phase_v2: 1))
    end

    it 'opens the Push page on the folder of the pending script' do
      sql_path = '/home/x/goggles_admin2/crawler/data/results.new/242/0001-a-lt4.sql'
      expect(described_class.link_path(action(:push, sql_path:))).to eq('/push/index?curr_dir=data%2Fresults.new%2F242')
      expect(described_class.link_path(action(:push, sql_path: '/x.sql'))).to eq('/push/index')
    end

    it 'is nil for the other actions or no action' do
      expect(described_class.link_path(action(:crawl, url: 'u'))).to be_nil
      expect(described_class.link_path(nil)).to be_nil
    end
  end

  describe '.post_path' do
    it 'returns the board action of the POST actions' do
      expect(described_class.post_path(action(:crawl, url: 'u'))).to eq(season_board_crawl_path)
      expect(described_class.post_path(action(:check_results, url: 'u', meeting_id: 1))).to eq(season_board_crawl_path)
      expect(described_class.post_path(action(:extract_manifest, pdf_path: '/x.pdf'))).to eq(season_board_extract_path)
      expect(described_class.post_path(action(:push, sql_path: '/x.sql'))).to be_nil
    end
  end

  describe '.target_for' do
    it 'gives a GET for the link actions' do
      target = described_class.target_for(action(:review_results, file_path: '/d/r.json'))
      expect(target).to have_attributes(http_method: :get, path: review_sessions_path(file_path: '/d/r.json', phase_v2: 1), params: {})
      expect(target).not_to be_post
    end

    it 'gives a POST of the FIN event id only for the POST actions' do
      target = described_class.target_for(action(:crawl, url: 'https://evil.example/'))
      expect(target).to have_attributes(http_method: :post, path: season_board_crawl_path, params: { fin_event_id: '150091' })
      expect(target).to be_post
    end

    it 'sends :link to the board row (the calendar is chosen there)' do
      expect(described_class.target_for(action(:link, bases: ['b'])))
        .to have_attributes(http_method: :get, path: season_board_path(anchor: 'season-board-row-150091'))
      expect(described_class.board_row_path('150091', state: :archived_unlinked))
        .to eq(season_board_path(state: 'archived_unlinked', anchor: 'season-board-row-150091'))
    end

    it 'is nil without an action or for an unknown kind' do
      expect(described_class.target_for(nil)).to be_nil
      expect(described_class.target_for(action(:unknown))).to be_nil
    end
  end

  it 'classifies the action kinds (Symbols or Strings)' do
    expect(described_class.link?(:push)).to be true
    expect(described_class.link?('resume_review')).to be true
    expect(described_class.post?('crawl')).to be true
    expect(described_class.post?(:link)).to be false
    expect(described_class.link?(nil)).to be false
  end
end
