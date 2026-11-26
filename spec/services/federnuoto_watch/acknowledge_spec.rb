# frozen_string_literal: true

require 'rails_helper'

# 0.10.103: the one way a pending FIN change is acknowledged (the operator's dismiss and the automatic one).
RSpec.describe FedernuotoWatch::Acknowledge do
  let(:tmp_dir) { Dir.mktmpdir('fin-ack') }
  let(:store) { FedernuotoWatch::StateStore.new(path: File.join(tmp_dir, 'state.json')) }
  let(:notifier) { instance_double(FedernuotoWatch::Notifier, clear_change: nil) }
  let(:gone) { { 'key' => 'gone', 'name' => 'Gone meeting', 'url' => '', 'date' => '01/12', 'year' => '2026', 'place' => 'Bari' } }
  let(:no_link) { { 'key' => 'nl', 'name' => 'No link yet', 'url' => '', 'date' => '02/12', 'year' => '2026', 'place' => 'Roma' } }
  let(:change) { { 'detected_at' => Time.current.iso8601, 'added' => [no_link], 'removed' => [gone], 'with_results' => [], 'updated' => [] } }

  def acknowledge(**options)
    described_class.call(store:, notifier:, actor: :auto, reason: 'nothing_to_crawl', **options)
  end

  before(:each) { store.update { { 'digest' => 'd2', 'rows' => [], 'ack_digest' => 'd1', 'change' => change } } }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  it 'acknowledges the change, drops its progress and removes the alert from every tab' do
    FedernuotoWatch::Progress.store!('digest' => 'd2', 'actionable' => 1)
    result = acknowledge(expected_digest: 'd2')
    expect(result).to be_acknowledged
    expect(result.change).to eq(change)
    expect(store.read).to include('ack_digest' => 'd2', 'change' => nil)
    expect(notifier).to have_received(:clear_change)
    expect(FedernuotoWatch::Progress.read('d2')).to be_nil
  end

  it 'does nothing when a newer snapshot landed since the caller looked (the digest race)' do
    result = acknowledge(expected_digest: 'd1')
    expect(result).not_to be_acknowledged
    expect(store.pending_change).to eq(change)
    expect(notifier).not_to have_received(:clear_change)
    expect(Ops::Event.where(kind: 'fin.watch_acknowledged')).to be_empty
  end

  it 'records an automatic acknowledge with its notices (rows without a link, true removals)' do
    result = acknowledge(expected_digest: 'd2')
    ack = Ops::Event.find_by(kind: 'fin.watch_acknowledged')
    expect(ack).to have_attributes(actor: 'job', subject_key: 'd2', link_path: '/season_board')
    expect(ack.data).to include('actor' => 'auto', 'reason' => 'nothing_to_crawl', 'added' => 1, 'removed' => 1)
    expect(result.notice_event).to have_attributes(kind: 'fin.calendar_notice', actor: 'job', subject_key: 'd2')
    expect(result.notice_event.data['removed'].pluck('name')).to eq(['Gone meeting'])
    expect(result.notice_event.data['without_link'].pluck('name')).to eq(['No link yet'])
    expect(result.notice_event.data).to include('text_only' => false, 'reason' => 'nothing_to_crawl')
  end

  it "uses the parity's notices when given (and its actionable count)" do
    notices = FedernuotoWatch::Parity::Notices.new(without_link: [], removed: [], text_only: true)
    parity = instance_double(FedernuotoWatch::Parity::Result, notices:, actionable: [1, 2])
    result = acknowledge(reason: 'parity', parity:)
    expect(Ops::Event.find_by(kind: 'fin.watch_acknowledged').data).to include('reason' => 'parity', 'actionable' => 2)
    expect(result.notice_event.data).to include('text_only' => true, 'removed' => [])
  end

  it 'records no notice for the operator dismiss (the alert listed every row)' do
    result = acknowledge(actor: :operator, reason: 'operator')
    expect(result).to be_acknowledged
    expect(Ops::Event.find_by(kind: 'fin.watch_acknowledged')).to have_attributes(actor: 'operator')
    expect(Ops::Event.where(kind: 'fin.calendar_notice')).to be_empty
  end

  it 'records no notice when the change holds none' do
    store.update { |state| state.merge('change' => { 'detected_at' => Time.current.iso8601, 'added' => [{ 'key' => 'x', 'url' => 'https://www.federnuoto.it/a#/risultati/1:m.html' }] }) }
    expect(acknowledge(reason: 'parity').notice_event).to be_nil
  end

  describe 'fail closed (an automatic acknowledge needs its trace written first)' do
    it 'acknowledges nothing automatically without the ops DB (the operator dismiss still works)' do
      allow(Ops).to receive(:available?).and_return(false)
      expect(acknowledge).not_to be_acknowledged
      expect(store.pending_change).to eq(change)
      expect(acknowledge(actor: :operator, reason: 'operator')).to be_acknowledged
    end

    it 'acknowledges nothing when the notice or the acknowledge event cannot be written (a locked ops DB)' do
      allow(Ops::Event).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
      expect(acknowledge).not_to be_acknowledged
      expect(store.read).to include('ack_digest' => 'd1', 'change' => change)
      expect(notifier).not_to have_received(:clear_change)
    end

    it 'writes the trace before the state: the notice, then the acknowledge event' do
      acknowledge
      expect(Ops::Event.order(:id).pluck(:kind)).to eq(%w[fin.calendar_notice fin.watch_acknowledged])
    end
  end

  describe 'duplicate acknowledges' do
    it 'acknowledges a digest once: a second caller (the watcher and the planner at the same minute) writes no event' do
      expect(acknowledge(expected_digest: 'd2')).to be_acknowledged
      expect(acknowledge(expected_digest: 'd2')).not_to be_acknowledged
      expect(Ops::Event.where(kind: 'fin.watch_acknowledged').count).to eq(1)
      expect(Ops::Event.where(kind: 'fin.calendar_notice').count).to eq(1)
    end

    it 'logs no ghost event for an operator dismiss right after an automatic acknowledge' do
      acknowledge
      expect(acknowledge(actor: :operator, reason: 'operator')).not_to be_acknowledged
      expect(Ops::Event.where(kind: 'fin.watch_acknowledged').pluck(:actor)).to eq(['job'])
    end

    it 'reuses the notice of the same change after a refused acknowledge' do
      allow(Ops).to receive(:record_event!).and_call_original
      allow(Ops).to receive(:record_event!).with(hash_including(kind: 'fin.watch_acknowledged')).and_return(nil)
      expect(acknowledge).not_to be_acknowledged
      allow(Ops).to receive(:record_event!).and_call_original
      expect(acknowledge).to be_acknowledged
      expect(Ops::Event.where(kind: 'fin.calendar_notice').count).to eq(1)
    end
  end

  it 'never raises: a failing broadcast is only logged, a failing store write returns not acknowledged' do
    allow(notifier).to receive(:clear_change).and_raise(RuntimeError, 'cable down')
    expect(acknowledge).to be_acknowledged
    allow(store).to receive(:acknowledge!).and_raise(Errno::EACCES)
    expect(acknowledge).not_to be_acknowledged
  end
end
