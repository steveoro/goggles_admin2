# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FedernuotoWatch::Fetcher do
  let(:chrome_bin) { '/usr/bin/true' }
  let(:success) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:failure) { instance_double(Process::Status, success?: false, exitstatus: 124) }

  it 'raises a FetchError when the Chrome executable is missing' do
    expect { described_class.new(chrome_bin: '/non/existing/chrome').call }
      .to raise_error(FedernuotoWatch::FetchError, /CHROME_BIN/)
  end

  it 'returns the dumped DOM, running headless Chrome through timeout' do
    allow(Open3).to receive(:capture3).and_return(['<html>ok</html>', '', success])
    expect(described_class.new(chrome_bin:, timeout: 42).call).to eq('<html>ok</html>')
    expect(Open3).to have_received(:capture3).with(
      'timeout', '42', chrome_bin, '--headless=new', any_args, '--dump-dom', /\A--user-data-dir=/, '--', FedernuotoWatch::URL
    )
  end

  it 'retries on failures and returns the first successful result' do
    allow(Open3).to receive(:capture3).and_return(['', 'boom', failure], ['<html>ok</html>', '', success])
    expect(described_class.new(chrome_bin:, retry_delay: 0).call).to eq('<html>ok</html>')
    expect(Open3).to have_received(:capture3).twice
  end

  it 'raises a FetchError after all the attempts fail' do
    allow(Open3).to receive(:capture3).and_return(['', 'boom', failure])
    expect { described_class.new(chrome_bin:, tries: 2, retry_delay: 0).call }
      .to raise_error(FedernuotoWatch::FetchError, /after 2 attempts.*exit=124/)
    expect(Open3).to have_received(:capture3).twice
  end
end
