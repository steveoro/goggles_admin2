# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportStatusChannel do
  it 'streams the broadcasts of Import::Progress::Cable (the progress strip under the top bar)' do
    subscribe
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from(Import::Progress::Cable::CHANNEL)
  end
end
