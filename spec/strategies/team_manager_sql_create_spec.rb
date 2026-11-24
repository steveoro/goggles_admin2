# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TeamManagerSqlCreate do
  let(:season) { FactoryBot.create(:season) }
  let(:team) { FactoryBot.create(:team) }
  let(:user) { FactoryBot.create(:user) }

  # (temporary crawler data root: never writes under the real crawler/data)
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:result_dir) { data_root.join("results.new/#{season.id}") }

  after(:each) { FileUtils.rm_rf(data_root) }

  context 'when any of the 3 entities is missing,' do
    subject(:creator) { described_class.new(season_id: season.id, team_id: 0, user_id: user.id, data_root:) }

    it 'returns false and collects a descriptive error' do
      expect(creator.call).to be(false)
      expect(creator.errors.join(', ')).to include('Team').and include('(ID: 0)')
    end

    it 'creates no rows' do
      expect { creator.call }.not_to(change(GogglesDb::ManagedAffiliation, :count))
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  context 'when the team has no affiliation for the chosen season,' do
    subject(:creator) { described_class.new(season_id: season.id, team_id: team.id, user_id: user.id, data_root:) }

    context 'when the team has a previous affiliation,' do
      let!(:previous_affiliation) do
        FactoryBot.create(:team_affiliation, team: team, name: 'Inherited Name', compute_gogglecup: true)
      end

      it 'returns true' do
        expect(creator.call).to be(true)
      end

      it 'creates both the team_affiliations & the managed_affiliations rows' do
        expect { creator.call }
          .to change(GogglesDb::TeamAffiliation, :count).by(1)
          .and change(GogglesDb::ManagedAffiliation, :count).by(1)
      end

      it 'inherits name/number/compute_gogglecup from the latest previous affiliation' do
        creator.call
        expect(creator.affiliation).to be_a(GogglesDb::TeamAffiliation).and be_persisted
        expect(creator.affiliation.name).to eq(previous_affiliation.name)
        expect(creator.affiliation.number).to eq(previous_affiliation.number)
        expect(creator.affiliation.compute_gogglecup).to eq(previous_affiliation.compute_gogglecup)
        expect(creator.affiliation.autofilled).to be(true)
      end

      it 'writes a progressive-numbered SQL batch file under results.new/<season_id>' do
        creator.call
        expect(creator.file_path).to be_present
        expect(File.exist?(creator.file_path)).to be(true)
        expect(File.dirname(creator.file_path)).to eq(result_dir.to_s)
        expect(File.basename(creator.file_path)).to match(/\A\d{4}-team_manager-\d+-\d+\.sql\z/)
      end

      it 'writes the same bytes as before the Outbox and registers the script' do
        creator.call
        expect(File.binread(creator.file_path)).to eq("#{creator.sql_log.join("\r\n")}\r\n".b)
        expect(creator.script.reload).to have_attributes(kind: 'team_manager', state: 'pending', folder: season.id.to_s,
                                                         season_id: season.id, applied_locally: true)
      end

      it 'continues the global sequence in an empty season folder' do
        write_sql_file(data_root, 'results.sent/misc/0476-merge_teams-1-2.sql')
        creator.call
        expect(File.basename(creator.file_path)).to start_with('0477-team_manager-')
      end

      it 'leaves neither file nor Outbox row when the local creation fails after the write' do
        # (the script is written, then the local transaction fails before its COMMIT)
        allow(creator).to receive(:write_sql_file).and_wrap_original do |original| # rubocop:disable RSpec/SubjectStub
          original.call
          raise ActiveRecord::RecordInvalid
        end
        expect { expect(creator.call).to be(false) }.not_to change(Ops::SqlScript, :count)
        expect(result_dir.glob('*.sql')).to be_empty
        expect(creator.file_path).to be_nil
      end

      it 'logs both INSERTs inside a single transaction in the generated file' do
        creator.call
        sql_content = File.read(creator.file_path)
        expect(sql_content).to include('START TRANSACTION')
          .and include('INSERT INTO `team_affiliations`')
          .and include('INSERT INTO `managed_affiliations`')
          .and include('COMMIT')
        expect(sql_content.index('INSERT INTO `team_affiliations`'))
          .to be < sql_content.index('INSERT INTO `managed_affiliations`')
      end
    end

    context 'when the team has NO previous affiliation at all,' do
      it 'creates the affiliation with fallback defaults' do
        expect(creator.call).to be(true)
        expect(creator.affiliation.name).to eq(team.name)
        expect(creator.affiliation.number).to eq('?')
        expect(creator.affiliation.compute_gogglecup).to be(false)
        expect(creator.affiliation.autofilled).to be(true)
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  context 'when the affiliation exists but the user is not yet linked as manager,' do
    subject(:creator) { described_class.new(season_id: season.id, team_id: team.id, user_id: user.id, data_root:) }

    let!(:affiliation) { FactoryBot.create(:team_affiliation, team: team, season: season) }

    it 'returns true' do
      expect(creator.call).to be(true)
    end

    it 'creates only the managed_affiliations row' do
      expect { creator.call }
        .to not_change { GogglesDb::TeamAffiliation.count }
        .and change(GogglesDb::ManagedAffiliation, :count).by(1)
      expect(creator.managed_affiliation.team_affiliation_id).to eq(affiliation.id)
      expect(creator.managed_affiliation.user_id).to eq(user.id)
    end

    it 'logs only the managed_affiliations INSERT in the generated file' do
      creator.call
      sql_content = File.read(creator.file_path)
      expect(sql_content).to include('INSERT INTO `managed_affiliations`')
      expect(sql_content).not_to include('INSERT INTO `team_affiliations`')
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  context 'when the managed_affiliations row already exists,' do
    subject(:creator) { described_class.new(season_id: season.id, team_id: team.id, user_id: user.id, data_root:) }

    let!(:affiliation) { FactoryBot.create(:team_affiliation, team: team, season: season) }

    before(:each) do
      FactoryBot.create(:managed_affiliation, team_affiliation: affiliation, manager: user)
    end

    it 'returns false and collects a descriptive error' do
      expect(creator.call).to be(false)
      expect(creator.errors.join(', ')).to include(affiliation.id.to_s).and include(user.id.to_s)
    end

    it 'creates no rows and writes no file' do
      expect { creator.call }.not_to(change(GogglesDb::ManagedAffiliation, :count))
      expect(creator.file_path).to be_nil
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  context 'when the SQL file cannot be written,' do
    subject(:creator) { described_class.new(season_id: season.id, team_id: team.id, user_id: user.id, data_root:) }

    before(:each) do
      allow(File).to receive(:write).and_raise(Errno::EIO, 'forced I/O error')
    end

    it 'returns false, collects the error and rolls back the local rows' do
      expect { expect(creator.call).to be(false) }
        .to not_change { GogglesDb::TeamAffiliation.count }
        .and(not_change { GogglesDb::ManagedAffiliation.count })
      expect(creator.errors.join(', ')).to include('forced I/O error')
      expect(data_root.glob('**/*.sql')).to be_empty
    end
  end
end
