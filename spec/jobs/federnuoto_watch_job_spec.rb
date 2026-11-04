# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FedernuotoWatchJob do
  before(:each) { allow(FedernuotoWatch::Checker).to receive(:call).and_return(:unchanged) }

  it 'runs a scheduled (non-manual) check by default' do
    described_class.perform_now
    expect(FedernuotoWatch::Checker).to have_received(:call).with(manual: false)
  end

  it 'runs a manual check when requested' do
    described_class.perform_now(manual: true)
    expect(FedernuotoWatch::Checker).to have_received(:call).with(manual: true)
  end

  it 'is enqueued on the default queue' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('default')
  end

  it 'is scheduled as a recurring task' do
    recurring = ActiveSupport::ConfigurationFile.parse(Rails.root.join('config/recurring.yml'))
    expect(recurring.dig('production', 'federnuoto_watch')).to include('class' => described_class.name)
    expect(recurring.dig('development', 'federnuoto_watch', 'schedule')).to be_present
  end
end
