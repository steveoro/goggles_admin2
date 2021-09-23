require "rails_helper"

RSpec.describe PageLinksForArrayComponent, type: :component do
  context 'with valid parameters,' do
    let(:sample_per_page) { [5, 10, 15, 20, 25, 30].sample }
    let(:rendered_content) do
      render_inline(
        described_class.new(
          data: sample_data,
          total_count: sample_tot,
          page: sample_page,
          per_page: sample_per_page
        )
      )
    end
    let(:sample_data) { (1..sample_per_page).to_a }
    let(:sample_tot)  { sample_data.count + (rand * 500).to_i }
    let(:sample_page) { (1..(sample_tot / sample_per_page)).to_a.sample }

    before(:each) do
      allow(controller).to receive(:params).and_return(
        {
          controller: 'api_import_queues', # (full CRUD)
          action: 'index',
          page: sample_page,
          per_page: sample_per_page
        }
      )
    end

    it 'renders the paginator controls' do
      expect(rendered_content.css('#paginator-controls')).to be_present
    end

    it 'renders the first page link' do
      expect(rendered_content.css('span.first a.page-link')).to be_present unless sample_page == 1
    end

    it 'renders the prev page link' do
      expect(rendered_content.css('span.prev a.page-link')).to be_present unless sample_page == 1
    end

    it 'renders the next page link' do
      expect(rendered_content.css('span.next a.page-link')).to be_present
    end

    it 'renders the last page link' do
      expect(rendered_content.css('span.last a.page-link')).to be_present
    end
  end
end
