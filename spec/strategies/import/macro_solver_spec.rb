# frozen_string_literal: true

require 'rails_helper'

module Import
  RSpec.describe MacroSolver, type: :strategy do
    # TODO mappers & solvers

    describe '#find_or_prepare_city()' do
      context 'when looking for an existing GogglesDb::City' do
        describe 'it returns an Import::Entity that:' do
          it '1) has the searched row as #row member'
          it '2) has a non-empty #matches array that includes the main result #row'
        end
      end

      context 'when looking for an brand new GogglesDb::City (not yet existing)' do
        describe 'it prepares a new Import::Entity that:' do
          it '1) has the new row as #row member'
          it '2) has an empty #matches array'
        end
      end
    end
    #-- -----------------------------------------------------------------------
    #++

    describe '#find_or_prepare_meeting()'
    describe '#find_or_prepare_pool()'
    describe '#find_or_prepare_session()'
    describe '#find_or_prepare_mevent()'
    describe '#find_or_prepare_mprogram()'
    describe '#find_or_prepare_team()'
    describe '#find_or_prepare_affiliation()'
    describe '#select_gender_type()'
    describe '#find_or_prepare_swimmer()'
    describe '#find_or_prepare_badge()'
    describe '#find_or_prepare_mir()'

    describe '#cached_instance_of()'
    describe '#rebuild_cached_entities_for()'
    describe '#entity_present?()'
    describe '#add_entity_with_key()'
    describe '#prepare_model_matches_and_bindings_for()'
    describe '#convert_search_item_to_model_for()'
    describe '#find_or_prepare_mir()'
    describe '#find_or_prepare_mir()'
    describe '#find_or_prepare_mir()'
    describe '#find_or_prepare_mir()'
    describe '#find_or_prepare_mir()'
    describe '#find_or_prepare_mir()'
  end
end
