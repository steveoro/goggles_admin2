# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfResults::ContextDAO, type: :strategy do
  let(:fixture_name) { "#{FFaker::Lorem.word}-#{(rand * 100).to_i}" }
  let(:fixture_rows) do
    [
      PdfResults::ContextDef.new(name: "#{FFaker::Lorem.word}-0", optional_if_empty: true),
      PdfResults::ContextDef.new(name: "#{FFaker::Lorem.word}-1", optional_if_empty: true)
    ]
  end
  let(:parent_fields) do
    [
      { name: 'category', format: '\\s*([UAM]\\d{2})\\s(Under|Master)\\s' },
      { name: 'gender', format: '\\s(Femmine|Maschi)' }
    ]
  end
  let(:fixture_fields) do
    [
      { name: 'rank', format: '\\s?(\\d{1,2}|SQ|RT|NP)\\s+' },
      { name: 'swimmer_name', format: "\\s+(\\D+(['`\\-\\.\\s]\\s?\\D+){1,4})\\s+" },
      { name: 'year_of_birth', format: '\\s+(\\d{4})\\s+' }
    ]
  end

  let(:parent_ctx) { PdfResults::ContextDef.new(name: 'category', fields: parent_fields) }
  let(:fixture_ctx) do
    PdfResults::ContextDef.new(
      name: fixture_name, parent: parent_ctx,
      fields: fixture_fields, rows: fixture_rows
    )
  end

  let(:fixture_rank) { (1 + (rand * 50)).to_i.to_s }
  let(:fixture_name) { FFaker::Name.name }
  let(:fixture_year) { (1980 + (rand * 50)).to_i.to_s }
  let(:parent_category) { (25 + (rand * 40)).to_i.to_s }
  let(:parent_gender) { %w[Femmine Maschi].sample }

  let(:parent_buffer) { "    M#{parent_category} Master #{parent_gender}" }
  let(:fixture_buffer) do
    " #{fixture_rank}    #{fixture_name}    #{fixture_year} \r\n\r\n"
  end

  let(:parent_dao) { parent_ctx.extract(parent_buffer, 0) }
  let(:extracted_dao) { fixture_ctx.extract(fixture_buffer, 0) }

  before(:each) do
    expect(parent_ctx).to be_a(PdfResults::ContextDef)
    expect(fixture_ctx).to be_a(PdfResults::ContextDef)

    expect(parent_buffer).to include(parent_category).and include(parent_gender)
    expect(fixture_buffer).to include(fixture_rank).and include(fixture_name).and include(fixture_year)

    expect(parent_ctx.valid?(parent_buffer, 0)).to be true
    expect(fixture_ctx.valid?(fixture_buffer, 0)).to be true

    expect(parent_dao).to be_a(described_class)
    expect(extracted_dao).to be_a(described_class)
    # Add the sibling to the parent:
    parent_dao.add_row(extracted_dao)
  end

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

      it 'is named as the source context' do
        expect(new_instance.name).to eq(fixture_ctx.name)
      end

      it 'has the same parent as the source context DAO\'s' do
        expect(new_instance.parent).to eq(fixture_ctx.dao.parent)
      end

      it 'has same key as the source context (which is a joined collection of all validated field values)' do
        expect(new_instance.key).to eq(fixture_ctx.key)
        expect(new_instance.key).to eq([fixture_rank, fixture_name, fixture_year].join('|'))
      end

      it 'has same key as the DAO resulting from extract' do
        expect(new_instance.key).to eq(extracted_dao.key)
      end

      it 'has an empty array of sibling DAO rows' do
        expect(new_instance.rows).to eq([])
      end

      it 'collects all fields from the source context into fields_hash' do
        expect(new_instance.fields_hash).to be_present
        expect(new_instance.fields_hash.keys)
          .to match_array(fixture_fields.map { |fld| fld.name })
        expect(new_instance.fields_hash.values)
          .to contain_exactly(fixture_rank, fixture_name, fixture_year)
      end

      it 'has same #data as the DAO resulting from extract()' do
        expect(new_instance.data).to eq(extracted_dao.data)
      end
    end

    context 'with a nil (default) parameter,' do
      subject(:new_instance) { described_class.new }

      it 'creates a new root DAO instance' do
        expect(new_instance).to be_a(described_class)
      end

      it 'is named \'root\'' do
        expect(new_instance.name).to eq('root')
      end

      it 'has a nil parent' do
        expect(new_instance.parent).to be_nil
      end

      it 'has a nil key' do
        expect(new_instance.key).to be_nil
      end

      it 'has an empty array of rows' do
        expect(new_instance.rows).to eq([])
      end

      it 'has an empty fields_hash' do
        expect(new_instance.fields_hash).to eq({})
      end
    end

    context 'with a non-valid parameter,' do
      subject(:new_instance) { described_class.new('Not a ContextDef or nil!') }

      it 'raises an error' do
        expect { new_instance }.to raise_error('Invalid ContextDef specified!')
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#data' do
    context 'when called on an instance from a ContextDef with valid? true & called,' do
      subject(:result) { new_instance.data }

      let(:new_instance) { described_class.new(fixture_ctx) }

      it 'is an Hash' do
        expect(result).to be_an(Hash).and be_present
      end

      it 'includes the DAO :name' do
        expect(result[:name]).to eq(new_instance.name)
      end

      it 'includes the DAO :key' do
        expect(result[:key]).to eq(new_instance.key)
      end

      it 'includes the DAO fields_hash as :fields' do
        expect(result[:fields]).to eq(new_instance.fields_hash)
      end

      # TODO: Add context w/ sibling DAO rows
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#find_existing(dao)' do
    subject(:new_instance) { described_class.new(fixture_ctx) }

    context 'when searching for a non-valid DAO,' do
      it 'returns nil' do
        expect(new_instance.find_existing('NOT-a-DAO')).to be_nil
      end
    end

    context 'when searching for nil,' do
      it 'returns nil' do
        expect(new_instance.find_existing(nil)).to be_nil
      end
    end

    context 'when searching for a DAO with the same name & key,' do
      it 'returns itself' do
        expect(new_instance.find_existing(new_instance)).to eq(new_instance)
      end
    end

    context 'when the specified DAO can be found in the hierarchy tree,' do
      it 'returns the correct DAO instance (with same name & key)' do
        found_dao = parent_dao.find_existing(new_instance)
        expect(found_dao).to be_a(described_class)
        expect(found_dao.name).to eq(new_instance.name)
        expect(found_dao.key).to eq(new_instance.key)
      end
    end

    context 'when the specified DAO cannot be found in the hierarchy below,' do
      it 'returns nil' do
        expect(new_instance.find_existing(parent_dao)).to be_nil
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#add_row(dao)' do
    context 'when the specified DAO is valid,' do
      xit 'adds it to the @row array' do
        # TODO
      end
    end

    context 'when the specified DAO is not valid,' do
      xit 'returns an error' do
        # TODO
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  describe '#merge(dao)' do
    context 'when the specified DAO\'s parent can be found in the hierarchy tree' do
      context 'the DAO is already existing (as a direct sibling of the parent),' do
        xit 'merges the specified DAO to the sibling rows of the parent found' do
          # TODO
        end
      end

      context 'but the DAO itself does not exists (as a direct sibling of the parent),' do
        xit 'adds the specified DAO to the sibling rows of the parent found' do
          # TODO
        end
      end
    end

    context 'when the specified DAO\'s parent cannot be found,' do
      xit 'adds the specified DAO \'as is\' to the sibling rows of this instance' do
        # TODO
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
#-- ---------------------------------------------------------------------------
#++
