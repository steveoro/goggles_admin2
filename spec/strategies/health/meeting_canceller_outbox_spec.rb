# frozen_string_literal: true

require 'rails_helper'

# Phase 07: the "Flag cancelled" script of Health::MeetingCanceller is registered in the SQL Outbox.
RSpec.describe Health::MeetingCanceller do
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:season) { closed_health_season }
  let(:meeting) { FactoryBot.create(:meeting, season:, cancelled: false) }

  after(:each) { FileUtils.rm_rf(data_root) }

  def cancel!
    digest = described_class.new(season:, meeting_id: meeting.id, data_root:).preview.digest
    described_class.new(season:, meeting_id: meeting.id, data_root:).call(expected_digest: digest)
  end

  it "registers the script as a pending 'cancel_flag' of the season folder" do
    result = cancel!
    script = Ops::SqlScript.find_by(filename: File.basename(result.sql_path))
    expect(script).to have_attributes(kind: 'cancel_flag', state: 'pending', folder: season.id.to_s, season_id: season.id)
    expect(script.origin).to include('producer' => 'health.flag_cancelled', 'meeting_id' => meeting.id)
  end

  it 'leaves neither file nor Outbox row when the local transaction fails after the write' do
    allow_any_instance_of(described_class).to receive(:write_sql_file).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
      original.call(*args)
      raise ActiveRecord::StatementInvalid, 'lock wait timeout'
    end
    expect { expect(cancel!).not_to be_success }.not_to change(Ops::SqlScript, :count)
    expect(Dir.glob(data_root.join('**', '*.sql').to_s)).to be_empty
    expect(meeting.reload.cancelled).to be(false)
  end
end
