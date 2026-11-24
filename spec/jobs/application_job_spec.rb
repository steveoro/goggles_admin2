# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationJob do
  before(:each) do
    stub_const('SpecSourceJob', Class.new(described_class) { def perform = Current.source })
  end

  after(:each) { Current.reset }

  it 'sets Current.source to the job class while it runs (remote-write log), restoring the previous value' do
    Current.source = 'pull#index'
    expect(SpecSourceJob.perform_now).to eq('SpecSourceJob')
    expect(Current.source).to eq('pull#index')
  end
end
