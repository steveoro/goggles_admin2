# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfResults::FormatParser, type: :strategy do
  describe 'a new instance,' do
    context 'when given a valid text file,' do
      subject(:new_instance) { described_class.new(tmp_file.path, skip_logging: true) }

      let(:tmp_file) do
        f = Tempfile.new(['test_202212345678_results', '.txt'])
        f.write("Season 2022/2023\nSome content\n")
        f.rewind
        f
      end

      after(:each) { tmp_file.close! }

      it 'creates a new FormatParser instance' do
        expect(new_instance).to be_a(described_class)
      end

      it 'responds to #document' do
        expect(new_instance).to respond_to(:document)
      end

      it 'responds to #pages' do
        expect(new_instance).to respond_to(:pages)
      end

      it 'responds to #season' do
        expect(new_instance).to respond_to(:season)
      end

      it 'responds to #format_name' do
        expect(new_instance).to respond_to(:format_name)
      end

      it 'responds to #root_dao' do
        expect(new_instance).to respond_to(:root_dao)
      end

      it 'responds to #scan' do
        expect(new_instance).to respond_to(:scan)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # TODO: Add tests for #scan with actual format fixture files
end
