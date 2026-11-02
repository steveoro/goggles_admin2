# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfManifests::DevinClient, type: :strategy do
  let(:client) { described_class.new(model: 'swe-2-high') }
  let(:status_ok) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:status_fail) { instance_double(Process::Status, success?: false, exitstatus: 1) }
  let(:payload) { { 'meeting_name' => 'TEST MEETING', 'events' => [] }.to_json }

  describe '#initialize' do
    it 'defaults to swe-2-high and mirrors it as the vision model' do
      expect(client.model).to eq('swe-2-high')
      expect(client.vision_model).to eq('swe-2-high')
    end

    it 'honours DEVIN_MANIFEST_MODEL' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('DEVIN_MANIFEST_MODEL', 'swe-2-high').and_return('swe-2-max')
      expect(described_class.new.model).to eq('swe-2-max')
    end
  end

  describe '#available? / #model_available?' do
    let(:models_json) do
      { 'families' => [
        { 'slug' => 'swe-2', 'family_uid' => 'swe-2', 'aliases' => ['swe'],
          'variants' => [{ 'model_uid' => 'swe-2-high' }, { 'model_uid' => 'swe-2-max' }] }
      ] }.to_json
    end

    before(:each) { allow(described_class).to receive(:installed?).and_return(true) }

    it 'is available (and vision-capable) when the CLI answers the models list' do
      allow(Open3).to receive(:capture3).and_return([models_json, '', status_ok])
      expect(client).to be_available
      expect(client).to be_vision_available
    end

    it 'is not available when the CLI call fails' do
      allow(Open3).to receive(:capture3).and_return(['', 'not logged in', status_fail])
      expect(client).not_to be_available
    end

    it 'is not available without the devin binary' do
      allow(described_class).to receive(:installed?).and_return(false)
      expect(client).not_to be_available
    end

    it 'checks model membership against variants, family slugs and aliases' do
      allow(Open3).to receive(:capture3).and_return([models_json, '', status_ok])
      expect(client.model_available?('swe-2-high')).to be(true)
      expect(client.model_available?('swe-2')).to be(true)
      expect(client.model_available?('swe')).to be(true)
      expect(client.model_available?('gemma4:e4b')).to be(false)
    end

    it 'does not block on an unparseable model list' do
      allow(Open3).to receive(:capture3).and_return(['weird output', '', status_ok])
      expect(client.model_available?('anything')).to be(true)
    end
  end

  describe '#generate' do
    it 'returns the parsed JSON object printed on stdout' do
      allow(Open3).to receive(:capture3).and_return([payload, '', status_ok])
      expect(client.generate(prompt: 'extract')).to eq(JSON.parse(payload))
    end

    it 'accepts a markdown-fenced JSON reply' do
      allow(Open3).to receive(:capture3).and_return(["here:\n```json\n#{payload}\n```\nthanks", '', status_ok])
      expect(client.generate(prompt: 'extract')).to eq(JSON.parse(payload))
    end

    it 'accepts JSON embedded in surrounding prose' do
      allow(Open3).to receive(:capture3).and_return(["sure! #{payload} done", '', status_ok])
      expect(client.generate(prompt: 'extract')).to eq(JSON.parse(payload))
    end

    it 'retries once on invalid JSON then returns the parsed reply' do
      allow(Open3).to receive(:capture3).and_return(['no json here', '', status_ok], [payload, '', status_ok])
      expect(client.generate(prompt: 'p')).to eq(JSON.parse(payload))
      expect(Open3).to have_received(:capture3).twice
    end

    it 'raises Error when both attempts return invalid JSON' do
      allow(Open3).to receive(:capture3).and_return(['nope', '', status_ok])
      expect { client.generate(prompt: 'p') }.to raise_error(PdfManifests::DevinClient::Error, /invalid JSON/)
      expect(Open3).to have_received(:capture3).twice
    end

    it 'raises Error on non-zero exit without retrying' do
      allow(Open3).to receive(:capture3).and_return(['', 'auth fail', status_fail])
      expect { client.generate(prompt: 'p') }.to raise_error(PdfManifests::DevinClient::Error, /auth fail/)
      expect(Open3).to have_received(:capture3).once
    end

    it 'raises a timeout Error when the run is killed' do
      timeout_status = instance_double(Process::Status, success?: false, exitstatus: 124)
      allow(Open3).to receive(:capture3).and_return(['', '', timeout_status])
      expect { client.generate(prompt: 'p') }.to raise_error(PdfManifests::DevinClient::Error, /timed out/)
    end

    it 'unsets agent-context env vars for the spawned devin process' do
      captured_env = nil
      allow(Open3).to receive(:capture3) do |env, *_args, **_kwargs|
        captured_env = env
        [payload, '', status_ok]
      end
      client.generate(prompt: 'p')
      expect(captured_env).to include('ACP_BACKEND' => nil, 'AI_AGENT' => nil)
    end

    it 'runs devin -p with the model, quiet verbosity and the prompt file' do
      argv = nil
      allow(Open3).to receive(:capture3) do |_env, *args, **_kwargs|
        argv = args
        [payload, '', status_ok]
      end
      client.generate(prompt: 'p')
      expect(argv).to include('devin', '--model', 'swe-2-high', '--verbosity', '0',
                              '--respect-workspace-trust', 'false', '-p', '--prompt-file')
    end

    context 'with images' do
      it 'writes page PNGs in the run dir and names them in the prompt' do
        seen_files = nil
        prompt_text = nil
        allow(Open3).to receive(:capture3) do |_env, *args, **kwargs|
          seen_files = Dir.glob(File.join(kwargs[:chdir], '*')).map { |f| File.basename(f) }.sort
          prompt_text = File.read(args[args.index('--prompt-file') + 1])
          [payload, '', status_ok]
        end
        client.generate(prompt: 'img prompt', images: %w[aGk= aG9sYQ==])

        expect(seen_files).to include('page-1.png', 'page-2.png', 'prompt.txt')
        expect(prompt_text).to include('img prompt', 'page-1.png', 'page-2.png')
      end
    end
  end
end
