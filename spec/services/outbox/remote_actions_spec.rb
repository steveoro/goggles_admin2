# frozen_string_literal: true

require 'rails_helper'

# APIProxy is stubbed in every example: the import queue is never touched for real.
RSpec.describe Outbox::RemoteActions do
  let(:data_root) { Pathname.new(Dir.mktmpdir) }
  let(:api_url) { 'http://localhost:8081' }
  let(:capabilities) { %w[iq_batch_outcome] }
  let(:failed) do
    create_sql_script(data_root, 'results.new/262/0010-a-lt4.sql', content: 'SELECT 1;', state: 'failed', remote_iq_id: 9123,
                                                                   target_api_url: api_url, remote_error: 'ERROR 1062')
  end

  before(:each) do
    allow(Outbox).to receive(:data_root).and_return(data_root)
    body = { msg: 'OK', environment: 'production', capabilities: }
    SystemStatus::APISnapshot.write!(api_url, DummyResponse.new(body: body.to_json), source: 'system_status')
  end

  after(:each) { FileUtils.rm_rf(data_root) }

  def answer(body)
    APIProxy::Result.new(DummyResponse.new(body: body.to_json))
  end

  def refused
    APIProxy::Result.new(instance_double(RestClient::Response, code: 422, body: '{}', headers: { x_error_detail: 'nope' }))
  end

  def queued = answer('id' => 1, 'done' => false, 'process_runs' => 0, 'error_messages' => nil)

  describe '.retry!' do
    it 'resets the server row in place and moves the unchanged file back to results.sent' do
      allow(APIProxy).to receive(:call).and_return(answer(true))
      described_class.retry!(failed, jwt: 'jwt')
      expect(APIProxy).to have_received(:call)
        .with(method: :put, url: 'import_queue/9123', jwt: 'jwt', base_url: api_url, payload: { error_messages: '', process_runs: 0 },
              open_timeout: 5, timeout: 20)
      expect(failed.reload).to have_attributes(state: 'sent', rel_path: 'results.sent/262/0010-a-lt4.sql', remote_error: nil,
                                               last_error: 'ERROR 1062', push_attempts: 1)
      expect(data_root.join('results.sent/262/0010-a-lt4.sql')).to exist
      expect(Ops::Event.last.kind).to eq('outbox.retried')
    end

    it 'refuses an edited file: withdraw it first' do
      allow(APIProxy).to receive(:call)
      File.write(failed.absolute_path, 'SELECT 2;')
      expect { described_class.retry!(failed, jwt: 'jwt') }.to raise_error(Outbox::Error, I18n.t('outbox.errors.retry_changed'))
      failed.update!(changed_after_push: true)
      File.write(failed.absolute_path, 'SELECT 1;')
      expect { described_class.retry!(failed, jwt: 'jwt') }.to raise_error(Outbox::Error)
      expect(APIProxy).not_to have_received(:call)
    end

    it 'keeps the script failed when the API refuses the call' do
      allow(APIProxy).to receive(:call).and_return(refused)
      expect { described_class.retry!(failed, jwt: 'jwt') }.to raise_error(Outbox::Error, /nope/)
      expect(failed.reload).to be_failed
    end

    it 'refuses a script that is not failed' do
      failed.update!(state: 'sent')
      expect { described_class.retry!(failed, jwt: 'jwt') }.to raise_error(Ops::SqlScript::InvalidTransition)
    end
  end

  describe '.withdraw!' do
    let!(:later) do
      create_sql_script(data_root, 'results.sent/262/0011-b-lt4.sql', state: 'sent', remote_iq_id: 9124, target_api_url: api_url)
    end
    let!(:elsewhere) do
      create_sql_script(data_root, 'results.sent/262/0012-c-lt4.sql', state: 'sent', remote_iq_id: 9125, target_api_url: 'http://other:447')
    end

    it 'deletes the later queued rows first, then the failed one, returning all of them to pending' do
      allow(APIProxy).to receive(:call) { |options| options[:method] == :get ? queued : answer(true) }
      withdrawn = described_class.withdraw!(failed, jwt: 'jwt')
      expect(withdrawn.map(&:filename)).to eq(%w[0011-b-lt4.sql 0010-a-lt4.sql])
      expect(later.reload).to have_attributes(state: 'pending', rel_path: 'results.new/262/0011-b-lt4.sql', remote_iq_id: nil)
      expect(later.withdrawn_at).to be_present
      expect(failed.reload).to have_attributes(state: 'pending', last_error: 'ERROR 1062')
      expect(elsewhere.reload).to be_sent
      expect(Ops::Event.where(kind: 'outbox.withdrawn').count).to eq(2)
    end

    it 'stops at a row that already ran, keeping the scripts withdrawn before it' do
      allow(APIProxy).to receive(:call) do |options|
        next answer(true) if options[:method] == :delete

        options[:url] == 'import_queue/9124' ? queued : answer('id' => 1, 'done' => true)
      end
      expect { described_class.withdraw!(failed, jwt: 'jwt') }
        .to raise_error(Outbox::Error, /\A#{Regexp.escape(I18n.t('outbox.errors.withdraw_stopped', count: 1, error: 'X').split('X').first)}/)
      expect(later.reload).to be_pending
      expect(failed.reload).to be_failed
    end
  end

  describe '.abandon!' do
    it 'deletes the failed row from the server and discards the script (state withdrawn)' do
      allow(APIProxy).to receive(:call) { |options| options[:method] == :get ? answer('id' => 1, 'error_messages' => 'x') : answer(true) }
      described_class.abandon!(failed, jwt: 'jwt', note: 'not needed')
      expect(APIProxy).to have_received(:call).with(hash_including(method: :delete, url: 'import_queue/9123'))
      expect(failed.reload).to have_attributes(state: 'withdrawn', note: 'not needed',
                                               rel_path: 'results.new/discarded/262/0010-a-lt4.sql')
      expect(failed).to be_history
    end

    it 'requires a note' do
      expect { described_class.abandon!(failed, jwt: 'jwt', note: '') }.to raise_error(Ops::SqlScript::InvalidTransition)
    end
  end

  context 'with an API that does not report the outcomes' do
    let(:capabilities) { [] }

    it 'refuses every remote action' do
      allow(APIProxy).to receive(:call)
      expect { described_class.retry!(failed, jwt: 'jwt') }.to raise_error(Outbox::Error, I18n.t('outbox.errors.no_outcome_capability'))
      expect { described_class.withdraw!(failed, jwt: 'jwt') }.to raise_error(Outbox::Error)
      expect(APIProxy).not_to have_received(:call)
    end
  end
end
