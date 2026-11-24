# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::Automation do
  it 'is on by default (no stored setting)' do
    expect(described_class::SWITCHES.map { |switch| described_class.enabled?(switch) }).to eq([true, true, true])
    expect(described_class).not_to be_paused
  end

  it 'stores a switch and records an automation.switched event' do
    expect(described_class.store!(:auto_extract, '0', user_id: 7)).to be false
    expect(described_class.enabled?(:auto_extract)).to be false
    expect(described_class.enabled?(:auto_prepare)).to be true
    event = Ops::Event.order(:id).last
    expect(event).to have_attributes(kind: 'automation.switched', subject_key: 'automation.auto_extract', actor: 'operator')
    expect(event.data).to include('switch' => 'auto_extract', 'value' => false, 'user_id' => 7)
    expect(described_class).to be_paused
  end

  it 'turns every sub-switch off with the master switch (their stored values kept)' do
    described_class.store!(:enabled, false)
    expect(described_class.switches.map(&:state)).to eq(%w[off paused paused])
    expect(described_class.stored(:auto_prepare)).to be true
  end

  %w[0 false off].each do |value|
    it "forces everything off with ADMIN2_AUTOMATION=#{value}" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('ADMIN2_AUTOMATION', '').and_return(value)
      expect(described_class).to be_env_off
      expect(described_class::SWITCHES.map { |switch| described_class.enabled?(switch) }).to eq([false, false, false])
    end
  end

  it 'keeps the master switch on but turns extraction and preparation off without the ops DB' do
    allow(Ops).to receive(:available?).and_return(false)
    expect(described_class.enabled?).to be true
    expect(described_class.enabled?(:auto_extract)).to be false
    expect(described_class.enabled?(:auto_prepare)).to be false
  end

  it 'fails closed: a switch that cannot be read (e.g. a locked ops DB) is off' do
    allow(Ops::Setting).to receive(:fetch).and_raise(ActiveRecord::StatementInvalid, 'database is locked')
    expect(described_class::SWITCHES.map { |switch| described_class.enabled?(switch) }).to eq([false, false, false])
    expect(described_class.switches.map(&:state)).to eq(%w[off off off])
  end

  it 'refuses an unknown switch' do
    expect { described_class.enabled?(:commit) }.to raise_error(ArgumentError)
  end
end
