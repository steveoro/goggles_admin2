# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfResults::FormatDef, type: :strategy do
  describe 'a new instance,' do
    context 'when given a valid ContextDef (with valid? true & called),' do
      subject(:new_instance) { described_class.new(fixture_ctx) }

      it 'creates a new DAO instance' do
        expect(new_instance).to be_a(described_class)
      end

      it_behaves_like(
        'responding to a list of methods',
        %i[
          name parent key rows fields_hash set_debug_mock_values data
          find_existing add_row merge to_s
        ]
      )
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#apply_lambda' do
    context 'when lambda is set and valid,' do
      # TODO
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#apply_format' do
    context 'when format is capturing and has captures,' do
      # TODO
    end

    context 'when format is NOT capturing but has matches,' do
      # TODO
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#apply_single_regexp' do
    context 'when the regexp is capturing and has captures,' do
      # TODO
    end

    context 'when the regexp is NOT capturing but has matches,' do
      # TODO
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
#-- ---------------------------------------------------------------------------
#++
