# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::IssueNav do
  describe '.for_list' do
    let(:flags) { [true, false, false, true, false, true, false] } # issues at positions 0, 3, 5

    it 'finds the nearest issue before and after the current page (per_page 2, page 2 = positions 2-3)' do
      nav = described_class.for_list(flags, page: 2, per_page: 2) { |page, position| "p#{page}##{position}" }
      expect(nav.total).to eq(3)
      expect(nav.offset).to eq(1)
      expect(nav.prev_url).to eq('p1#0')
      expect(nav.next_url).to eq('p3#5')
    end

    it 'has no URL past the ends' do
      nav = described_class.for_list(flags, page: 3, per_page: 3) { |page, position| "p#{page}##{position}" }
      expect(nav.prev_url).to eq('p2#5')
      expect(nav.next_url).to be_nil
      expect(described_class.for_list([false], page: 1, per_page: 10) { 'x' }.any?).to be(false)
    end
  end

  describe '.for_pages' do
    it 'skips the pages without issues' do
      nav = described_class.for_pages([2, 0, 1, 0, 3], page: 3) { |page, edge| "p#{page}-#{edge}" }
      expect(nav.total).to eq(6)
      expect(nav.offset).to eq(2)
      expect(nav.prev_url).to eq('p1-last')
      expect(nav.next_url).to eq('p5-first')
    end
  end

  it 'builds a single page state' do
    expect(described_class.single_page(4)).to have_attributes(total: 4, offset: 0, prev_url: nil, next_url: nil)
  end
end
