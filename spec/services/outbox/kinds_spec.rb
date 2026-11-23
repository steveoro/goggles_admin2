# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Outbox::Kinds do
  describe '.infer' do
    {
      '0490-2026-11-22-Campionato_Indoor-lt4.sql' => 'commit',
      '0100-2024-05-12-Campionati_Italiani_Master_di_Nuoto-all4m-l4.sql' => 'commit',
      '0090-2023-02-11-Trofeo_Swimming_Master_2023.sql' => 'commit',
      '0467-calendar_link-1691-150120.sql' => 'calendar_link',
      '0420-season_board_backfill-262.sql' => 'backfill',
      '0409-team_manager-10556-163.sql' => 'team_manager',
      '0500-meeting_cancel-19900.sql' => 'cancel_flag',
      '0501-calendar_cancel-1700.sql' => 'cancel_flag',
      '0300-merge_badges-214795-206552.sql' => 'merge',
      '0301-season_fix_252-merge_badges-1-autofix.sql' => 'merge',
      '010-20241009_171705-3-relay_badges-season_192.sql' => 'merge',
      '0302-dedup_swimmer_42.sql' => 'merge',
      '0181-fix_swimmer_in_badge-194977.sql' => 'fix',
      '0037-datafix_teams_for_meeting_19744-from_1163-to_12.manual.sql' => 'fix',
      '0200-fix_dup_results-season_252.sql' => 'check',
      '0201-purge_meeting-19000.sql' => 'purge',
      '0202-262-recompute_ranks.sql' => 'recompute',
      '0002-normalize_coded_names.sql' => 'normalize',
      '000-262-standard_timings.sql' => 'standard_timings',
      '0203-import_categories-252-262.sql' => 'categories',
      '0204-something_else.sql' => 'manual'
    }.each do |name, kind|
      it "infers '#{kind}' for #{name}" do
        expect(described_class.infer(name)).to eq(kind)
      end
    end

    it "infers 'goggle_cup' from the goggle_cups folder" do
      expect(described_class.infer('0001-whatever.sql', folder: 'goggle_cups')).to eq('goggle_cup')
    end
  end

  it 'lists every inferable kind among the known kinds' do
    expect(described_class::NAME_RULES.map(&:first) - described_class::ALL).to be_empty
  end

  describe '.single_transaction?' do
    it 'is true for a script with one COMMIT and no DDL' do
      expect(described_class.single_transaction?("START TRANSACTION;\r\nUPDATE x SET a=1;\r\nCOMMIT;\r\n")).to be true
    end

    it 'is false with more than one COMMIT or with DDL' do
      expect(described_class.single_transaction?("UPDATE x SET a=1;\nCOMMIT;\nUPDATE y SET b=2;\nCOMMIT;\n")).to be false
      expect(described_class.single_transaction?("ALTER TABLE x ADD COLUMN y INT;\nCOMMIT;\n")).to be false
    end
  end

  it 'holds the normalize and standard timings kinds as not applied locally by default' do
    expect(described_class.applied_locally_by_default?('normalize')).to be false
    expect(described_class.applied_locally_by_default?('standard_timings')).to be false
    expect(described_class.applied_locally_by_default?('merge')).to be true
  end
end
