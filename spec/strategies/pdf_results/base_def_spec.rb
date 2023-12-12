# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfResults::BaseDef, type: :strategy do
  let(:fixture_name) { "#{FFaker::Lorem.word}-#{(rand * 100).to_i}" }

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
