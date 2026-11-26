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

  # (0.10.103: the alert-or-acknowledge decision is injected; the default one reads the Season board)
  let(:decision) { [:alert, nil] }
  let(:decide) { ->(_change) { decision } }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def run_check(html = nil, manual: false, **options)
    allow(fetcher).to receive(:call).and_return(html) if html
    described_class.call(manual:, fetcher:, store:, decide:, **options)
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
          a_hash_including(dom_id: FedernuotoWatch::INFO_DOM_ID, html: a_string_including('text-bg-info', '10 meeting'))
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

      it "keeps each row's own detection time across the accumulating change (0.10.103)" do
        run_check(changed_html)
        first = store.pending_change['row_detected_at']
        expect(first['with_results'].keys.size).to eq(1)
        travel(1.hour) do
          run_check(changed_html.sub('<td>Rovigo</td>', '<td>Rovigo (RO)</td>'))
        end
        times = store.pending_change['row_detected_at']
        expect(times['with_results']).to eq(first['with_results'])
        expect(times['added'].values.first).not_to eq(first['added'].values.first)
        expect(store.read['digest']).to be_present
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
          a_hash_including(dom_id: FedernuotoWatch::INFO_DOM_ID, html: a_string_including('text-bg-danger', 'site down'))
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

  describe 'the decision on a new change (0.10.103)' do
    let(:acknowledged) { [] }
    let(:acknowledger) do
      lambda { |**args|
        acknowledged << args
        FedernuotoWatch::Acknowledge::Result.new(acknowledged: true, change: nil, notice_event: nil)
      }
    end

    before(:each) { run_check }

    it 'raises the alert (with the snapshot digest) when the decision says :alert' do
      allow(ActionCable.server).to receive(:broadcast)
      run_check(changed_html, acknowledger:)
      expect(ActionCable.server).to have_received(:broadcast).with(
        stream, a_hash_including(dom_id: FedernuotoWatch::ALERT_DOM_ID,
                                 html: a_string_including("data-federnuoto-watch-ack-digest-value='#{store.read['digest']}'"))
      )
      expect(acknowledged).to be_empty
    end

    context 'with nothing to crawl' do
      let(:parity) { instance_double(FedernuotoWatch::Parity::Result) }
      let(:decision) { [:nothing_to_crawl, parity] }

      it 'raises no alert and acknowledges the change at once (automatic, guarded by the digest)' do
        expect { expect(run_check(changed_html, acknowledger:)).to eq(:changed) }.not_to have_broadcasted_to(stream)
        expect(acknowledged).to eq([{ actor: :auto, reason: 'nothing_to_crawl', expected_digest: store.read['digest'], parity: }])
      end

      it 'raises the alert after all when the acknowledge is refused (its trace could not be written)' do
        refusing = ->(**_args) { FedernuotoWatch::Acknowledge::Result.new(acknowledged: false, change: nil, notice_event: nil) }
        expect { run_check(changed_html, acknowledger: refusing) }
          .to have_broadcasted_to(stream).with(a_hash_including(dom_id: FedernuotoWatch::ALERT_DOM_ID))
        expect(store.pending_change).to be_present
      end

      it 'tells the operator after a manual check' do
        expect { run_check(changed_html, manual: true, acknowledger:) }.to have_broadcasted_to(stream).with(
          a_hash_including(dom_id: FedernuotoWatch::INFO_DOM_ID,
                           html: a_string_including(CGI.escapeHTML(I18n.t('federnuoto_watch.check.nothing_to_crawl')).first(30)))
        )
      end

      it 'acknowledges through FedernuotoWatch::Acknowledge by default, logging the change and its notice' do
        allow(parity).to receive_messages(notices: FedernuotoWatch::Parity::Notices.new(without_link: [], removed: [{ 'name' => 'Bari' }], text_only: false),
                                          actionable: [])
        run_check(changed_html)
        expect(store.pending_change).to be_nil
        expect(Ops::Event.order(:id).last(3).map(&:kind)).to eq(%w[fin.watch_changed fin.calendar_notice fin.watch_acknowledged])
      end
    end

    context 'when the rows without a link wait for the Eventi calendar crawl' do
      let(:decision) { [:wait, nil] }

      it 'raises no alert and keeps the change pending' do
        expect { run_check(changed_html, acknowledger:) }.not_to have_broadcasted_to(stream)
        expect(acknowledged).to be_empty
        expect(store.pending_change).to be_present
      end

      it 'stores the progress of the parity at once, so the pages keep the alert hidden' do
        parity = FedernuotoWatch::Parity::Result.new(actionable: [], awaiting_calendar: [:row], notices: nil, calendar: :queued, automation: true)
        run_check(changed_html, decide: ->(_change) { [:wait, parity] }, acknowledger:)
        progress = FedernuotoWatch::Progress.read(store.read['digest'])
        expect(progress).to include('actionable' => 0, 'awaiting_calendar' => 1)
        expect(FedernuotoWatch::Progress.alert_shown?(store.pending_change, progress)).to be false
      end
    end

    it 'raises the alert when the decision fails or is unknown (fail safe)' do
      failing = ->(_change) { raise 'board unreadable' }
      expect { run_check(changed_html, decide: failing, acknowledger:) }
        .to have_broadcasted_to(stream).with(a_hash_including(dom_id: FedernuotoWatch::ALERT_DOM_ID))
      expect(acknowledged).to be_empty
    end
  end

  describe 'removed rows (0.10.103)' do
    it 'keeps the rows FIN removed since they were first seen, and drops them when they come back' do
      run_check
      run_check(changed_html)
      removed = store.read['removed_rows']
      expect(removed.pluck('name')).to eq(['1° Trofeo New Year Swim'])
      expect(removed.first['removed_at']).to be_present
      store.acknowledge!
      run_check(fixture_html) # (Bari is back, Rovigo is gone)
      expect(store.read['removed_rows'].pluck('name')).to eq(['2° Trofeo Città di Rovigo'])
    end

    it 'does not count a rename (same dates and place) as a removal' do
      run_check
      run_check(changed_html.sub('2° Trofeo Città di Rovigo', '2° Trofeo di Rovigo'))
      renamed = changed_html.sub('2° Trofeo Città di Rovigo', '2° Trofeo Città di Rovigo (rinominato)')
      run_check(renamed)
      expect(store.read['removed_rows'].pluck('name')).to eq(['1° Trofeo New Year Swim'])
    end
  end

  describe 'ops event log' do
    it 'records one fin.watch_changed event per detected change' do
      expect { run_check }.not_to change(Ops::Event, :count) # (baseline)
      expect { run_check(changed_html) }.to change(Ops::Event, :count).by(1)
      event = Ops::Event.last
      expect(event).to have_attributes(kind: 'fin.watch_changed', level: 'warning', actor: 'job', subject_type: 'fin_watch',
                                       subject_key: store.read['digest'])
      expect(event.data).to include('added' => 1, 'removed' => 1, 'with_results' => 1, 'updated' => 0)
      expect { run_check(changed_html) }.not_to change(Ops::Event, :count) # (unchanged)
    end

    it 'marks the manual checks as operator events' do
      run_check
      run_check(changed_html, manual: true)
      expect(Ops::Event.last).to have_attributes(kind: 'fin.watch_changed', actor: 'operator')
    end

    it 'returns :changed all the same when the event write fails' do
      run_check
      allow(Ops::Event).to receive(:create!).and_raise(ArgumentError, 'kaboom')
      expect(run_check(changed_html)).to eq(:changed)
    end
  end
end
