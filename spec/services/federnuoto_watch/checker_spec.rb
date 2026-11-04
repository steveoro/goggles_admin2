# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FedernuotoWatch::Checker do
  include ActiveSupport::Testing::TimeHelpers

  let(:fixture_html) { Rails.root.join('spec/fixtures/files/federnuoto/riepilogo-eventi.html').read }
  # Changed page: 1 meeting removed (Bari), 1 added, results published for another (Trento):
  let(:changed_html) do
    fixture_html
      .sub(%r{<tr>\s*<td>10/01</td>\s*<td>1° Trofeo New Year Swim</td>.*?</tr>}m, '')
      .sub("<td>Trento</td>\n<td>&nbsp;</td>", "<td>Trento</td>\n<td><a href=\"/home/results/1.html\">x</a></td>")
      .sub('</tbody>', "<tr><td>13/12</td><td>2° Trofeo Città di Rovigo</td><td>Rovigo</td><td>&nbsp;</td></tr>\n</tbody>")
  end

  let(:tmp_dir) { Dir.mktmpdir('fin-watch-checker') }
  let(:store) { FedernuotoWatch::StateStore.new(path: File.join(tmp_dir, 'state.json')) }
  let(:fetcher) { instance_double(FedernuotoWatch::Fetcher, call: fixture_html) }
  let(:stream) { AppNotificationsChannel::STREAM }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def run_check(html = nil, manual: false)
    allow(fetcher).to receive(:call).and_return(html) if html
    described_class.call(manual:, fetcher:, store:)
  end

  describe '.diff' do
    let(:old_rows) do
      [
        { 'key' => 'a', 'url' => '', 'info' => '' },
        { 'key' => 'b', 'url' => '', 'info' => '' },
        { 'key' => 'c', 'url' => '', 'info' => '' },
        { 'key' => 'd', 'url' => 'http://x', 'info' => '' }
      ]
    end
    let(:new_rows) do
      [
        { 'key' => 'b', 'url' => 'http://res', 'info' => '' },
        { 'key' => 'c', 'url' => '', 'info' => 'ANNULLATA' },
        { 'key' => 'd', 'url' => 'http://x', 'info' => '' },
        { 'key' => 'e', 'url' => '', 'info' => '' }
      ]
    end

    it 'classifies the added, removed, with_results & updated rows' do
      result = described_class.diff(old_rows, new_rows)
      expect(result['added'].pluck('key')).to eq(%w[e])
      expect(result['removed'].pluck('key')).to eq(%w[a])
      expect(result['with_results'].pluck('key')).to eq(%w[b])
      expect(result['updated'].pluck('key')).to eq(%w[c])
    end

    it 'supports a nil old list' do
      expect(described_class.diff(nil, new_rows)['added'].size).to eq(4)
    end
  end

  describe '#call' do
    context 'with the first run' do
      it 'records the baseline without alerting' do
        expect { expect(run_check).to eq(:baseline) }.not_to have_broadcasted_to(stream)
        state = store.read
        expect(state['digest']).to be_present
        expect(state['ack_digest']).to eq(state['digest'])
        expect(state['rows'].size).to eq(10)
        expect(state['change']).to be_nil
        expect(state['last_checked']).to be_present
      end
    end

    context 'when the page is unchanged' do
      before(:each) { run_check }

      it 'returns :unchanged without broadcasting for scheduled checks' do
        expect { expect(run_check).to eq(:unchanged) }.not_to have_broadcasted_to(stream)
      end

      it 'broadcasts a transient info message for manual checks' do
        expect { run_check(manual: true) }.to have_broadcasted_to(stream).with(
          a_hash_including(dom_id: FedernuotoWatch::INFO_DOM_ID, html: a_string_including('alert-info', '10 meeting'))
        )
      end
    end

    context 'when the page changes' do
      before(:each) { run_check }

      it 'stores the pending change diffed against the acknowledged snapshot' do
        expect(run_check(changed_html)).to eq(:changed)
        change = store.pending_change
        expect(change['added'].pluck('name')).to eq(['2° Trofeo Città di Rovigo'])
        expect(change['removed'].pluck('name')).to eq(['1° Trofeo New Year Swim'])
        expect(change['with_results'].pluck('place')).to eq(['Trento'])
        expect(change['updated']).to eq([])
        expect(change['detected_at']).to be_present
      end

      it 'broadcasts the sticky change alert (with no CSRF tokens)' do
        expect { run_check(changed_html) }.to have_broadcasted_to(stream).with(
          a_hash_including(
            dom_id: FedernuotoWatch::ALERT_DOM_ID,
            html: a_string_including('flash-sticky', '2° Trofeo Città di Rovigo', '1° Trofeo New Year Swim', 'Trento')
                  .and(satisfy { |html| html.exclude?('authenticity_token') })
          )
        )
      end

      it 'accumulates subsequent changes until acknowledged' do
        run_check(changed_html)
        first_detected_at = store.pending_change['first_detected_at']
        travel(1.hour) do
          run_check(changed_html.sub('<td>Rovigo</td>', '<td>Rovigo (RO)</td>'))
        end
        change = store.pending_change
        expect(change['added'].pluck('place')).to eq(['Rovigo (RO)'])
        expect(change['removed'].size).to eq(1)
        expect(change['first_detected_at']).to eq(first_detected_at)
        expect(change['detected_at']).not_to eq(first_detected_at)
      end

      it 'computes the next change from the acknowledged snapshot' do
        run_check(changed_html)
        store.acknowledge!
        expect(run_check(changed_html)).to eq(:unchanged)
        expect(run_check(fixture_html)).to eq(:changed)
        expect(store.pending_change['removed'].pluck('name')).to eq(['2° Trofeo Città di Rovigo'])
      end

      it 'clears the alert when the page returns to the acknowledged state' do
        run_check(changed_html)
        expect { expect(run_check(fixture_html)).to eq(:reverted) }.to have_broadcasted_to(stream).with(
          dom_id: FedernuotoWatch::ALERT_DOM_ID, html: ''
        )
        expect(store.pending_change).to be_nil
      end
    end

    context 'when the fetch fails' do
      before(:each) { allow(fetcher).to receive(:call).and_raise(FedernuotoWatch::FetchError, 'site down') }

      it 'stores the error and returns :error without raising' do
        expect(run_check).to eq(:error)
        expect(store.read['last_error']).to include('site down')
      end

      it 'does not broadcast for scheduled checks' do
        expect { run_check }.not_to have_broadcasted_to(stream)
      end

      it 'broadcasts an error message for manual checks' do
        expect { run_check(manual: true) }.to have_broadcasted_to(stream).with(
          a_hash_including(dom_id: FedernuotoWatch::INFO_DOM_ID, html: a_string_including('alert-danger', 'site down'))
        )
      end
    end

    context 'when the page layout is unexpected' do
      it 'returns :error keeping the previous snapshot' do
        run_check
        digest = store.read['digest']
        expect(run_check('<html><body>Maintenance</body></html>')).to eq(:error)
        expect(store.read).to include('digest' => digest, 'last_error' => a_string_including('ParseError'))
      end
    end
  end
end
