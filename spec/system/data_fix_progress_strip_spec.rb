# frozen_string_literal: true

require 'rails_helper'

# The progress strip under the top bar (Shell::ProgressStripComponent, run in both themes: SYSTEM_THEME=dark), fed by
# ImportStatusChannel, on the Data-Fix review pages of a temporary copy of the "sample-200RA-l4" fixtures. It replaced
# the modal progress dialog that stayed open over the review pages: the strip is an overlay that never moves the page
# nor stops a click, hides itself on 'done', and Back never restores it. The broadcasts are real (the test cable
# adapter delivers them to the browser); the raw ones play the out-of-order cases of the protocol.
RSpec.describe 'Data-Fix progress strip' do
  let(:fixtures_dir) { Rails.root.join('spec/fixtures/import') }
  let(:basename) { 'sample-200RA-l4' }
  let(:tmp_root) { Dir.mktmpdir('system-progress-strip-') }
  let(:work_dir) { File.join(tmp_root, '242') } # (the season ID is read from the folder name)
  let(:source_path) { File.join(work_dir, "#{basename}.json") }
  let(:panel) { '#progress-strip-panel' }
  let(:shown_panel) { '#progress-strip-panel:not([hidden])' }
  let(:message) { "#{shown_panel} [data-progress-strip-target='message']" }

  before(:each) do
    FileUtils.mkdir_p(work_dir)
    FileUtils.cp(Dir[fixtures_dir.join("#{basename}*.json")], work_dir)
    sign_in_admin(prepare_admin_user)
  end

  after(:each) { FileUtils.rm_rf(tmp_root) }

  def broadcast(payload)
    ActionCable.server.broadcast(Import::Progress::Cable::CHANNEL, payload)
  end

  def tick(op_id, seq, msg = "#{op_id} #{seq}", progress: seq, total: 10)
    broadcast({ op: op_id, seq:, scope: basename, msg:, progress:, total: })
  end

  # Ticks until the strip shows: the ImportStatusChannel subscription of a freshly loaded page is confirmed
  # asynchronously, and a message broadcast before that is lost. +sink+: an Import::Progress::Cable, or nil for a raw
  # 'warm-up' operation, ended at once (the subscription is then known to be live).
  def tick_until_shown(sink = nil, msg: 'warm-up', current: 1, total: 1)
    20.times do |index|
      sink ? sink.call(msg, current, total) : tick('warm-up', index + 1, msg)
      break if page.has_css?(shown_panel, wait: 0.5)
    end
    expect(page).to have_css(shown_panel)
    return if sink

    broadcast({ op: 'warm-up', state: 'done' })
    expect(page).to have_css(panel, visible: :hidden)
  end

  def expect_nothing_modal
    expect(page).to have_no_css('.modal-backdrop')
    expect(page).to have_no_css('body.modal-open')
    expect(page).to have_no_css('.modal.show')
  end

  def expect_still(selector, **options)
    sleep(0.7) # (a negative check: leave the message time to arrive)
    expect(page).to have_css(selector, **options)
  end

  def visit_step(number)
    path, flag = { 1 => [:review_sessions_path, :phase_v2], 2 => [:review_teams_path, :phase2_v2],
                   4 => [:review_events_path, :phase4_v2] }.fetch(number)
    visit(send(path, file_path: source_path, flag => 1))
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: "Step #{number}")
  end

  def top_of(selector)
    page.evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().top")
  end

  # Whether the Step 1 page cached by Turbo when leaving it has the panel hidden (what Back restores).
  def cached_step1_panel_hidden
    page.evaluate_script(<<~JS)
      (() => {
        const cache = window.Turbo.session.view.snapshotCache
        const key = Object.keys(cache.snapshots).find((url) => url.includes('review_sessions'))
        if (!key) return 'no snapshot'
        const cachedPanel = cache.snapshots[key].element.querySelector('#progress-strip-panel')
        return cachedPanel ? cachedPanel.hidden : 'no panel'
      })()
    JS
  end

  def file_state(path) = [File.binread(path), File.mtime(path)]

  it "shows a tick under the top bar (texts, count, bar, live region), never modal, and hides on 'done'" do
    visit_step(1)
    expect(page).to have_css(panel, visible: :hidden)

    sink = Import::Progress::Cable.new(scope: basename)
    tick_until_shown(sink, msg: 'Map teams', current: 3, total: 10)
    within(shown_panel) do
      expect(page).to have_css('[data-progress-strip-target="message"]', text: 'Map teams')
      expect(page).to have_css('[data-progress-strip-target="scope"]', text: basename)
      expect(page).to have_css('[data-progress-strip-target="count"]', text: '3/10')
      expect(page).to have_css('.progress[aria-valuenow="30"]')
    end
    expect(find('[data-progress-strip-target="status"]', visible: :all).text(:all)).to eq("#{basename}: Map teams")
    expect_nothing_modal

    sink.call('Map teams', 10, 10)
    expect(page).to have_css("#{shown_panel} [data-progress-strip-target='count']", text: '10/10')
    sink.done
    expect(page).to have_css(panel, visible: :hidden)
    expect_no_js_errors
  end

  it "is an overlay under the top bar: the page doesn't move and the clicks go through it" do
    visit_step(1)
    tabs_top = top_of('ul.nav-tabs')
    sink = Import::Progress::Cable.new(scope: basename)
    tick_until_shown(sink, msg: 'Map teams', current: 3, total: 10)

    expect(page).to have_css(".app-topbar #{shown_panel}")
    expect(top_of('ul.nav-tabs')).to eq(tabs_top)
    # (what a click on the strip's message hits: the page under it, never the strip)
    hit_inside_strip = page.evaluate_script(<<~JS)
      (() => {
        const box = document.querySelector('#progress-strip-panel [data-progress-strip-target="message"]').getBoundingClientRect()
        const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)
        return document.getElementById('progress-strip').contains(hit)
      })()
    JS
    expect(hit_inside_strip).to be(false)

    sink.done
    expect(page).to have_css(panel, visible: :hidden)
    expect(top_of('ul.nav-tabs')).to eq(tabs_top)
    expect_no_js_errors
  end

  it 'keeps the stepper tabs clickable while shown, caches the page with the strip hidden, and Back shows none' do
    visit_step(1)
    tick_until_shown(Import::Progress::Cable.new(scope: basename), msg: 'Map swimmers', current: 1, total: 4)

    find('ul.nav-tabs a.nav-link', text: 'Step 2').click
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 2')
    expect(page).to have_css(panel, visible: :hidden) # (a new page starts hidden)
    # (the turbo:before-cache reset: the snapshot Turbo took of Step 1 while the strip was shown has it hidden)
    expect(cached_step1_panel_hidden).to be(true)

    page.go_back
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 1')
    expect(page).to have_css(panel, visible: :hidden)
    expect_nothing_modal

    find('ul.nav-tabs a.nav-link', text: 'Step 3').click
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 3')
    expect_no_js_errors
  end

  it 'hides for the rest of the operation with its close button, and shows the next operation' do
    visit_step(1)
    sink = Import::Progress::Cable.new(scope: basename)
    tick_until_shown(sink, msg: 'Map teams', current: 1, total: 10)

    find("#{shown_panel} button.btn-close").click
    expect(page).to have_css(panel, visible: :hidden)
    sink.call('Map teams', 2, 10)
    expect_still(panel, visible: :hidden)

    sink.done
    sink.call('Populating phase 5...', 0, 100) # (a new operation after the 'done')
    expect(page).to have_css(message, text: 'Populating phase 5...')
    expect_no_js_errors
  end

  describe 'message order (Import::Progress::Cable: one op per operation, seq from 1, then done)' do
    before(:each) do
      visit_step(1)
      tick_until_shown
    end

    it 'keeps a late tick of a finished op hidden' do
      tick('A', 1, 'A one')
      expect(page).to have_css(message, text: 'A one')
      broadcast({ op: 'A', state: 'done' })
      expect(page).to have_css(panel, visible: :hidden)

      tick('A', 2, 'A late')
      expect_still(panel, visible: :hidden)
      expect_no_js_errors
    end

    it "starts over on a new op whatever its seq, and keeps it on another op's 'done'" do
      tick('A', 5, 'A five')
      expect(page).to have_css(message, text: 'A five')
      tick('B', 1, 'B one')
      expect(page).to have_css(message, text: 'B one')

      broadcast({ op: 'A', state: 'done' })
      expect_still(message, text: 'B one')
      broadcast({ op: 'B', state: 'done' })
      expect(page).to have_css(panel, visible: :hidden)
      expect_no_js_errors
    end

    it 'ignores an older or repeated seq of the current op' do
      tick('C', 3, 'C three')
      expect(page).to have_css(message, text: 'C three')
      tick('C', 2, 'C two (older)')
      expect_still(message, text: 'C three')
      tick('C', 3, 'C three (repeated)')
      expect_still(message, text: 'C three')
      expect(page).to have_no_css(message, text: 'repeated')
      tick('C', 4, 'C four')
      expect(page).to have_css(message, text: 'C four')
      expect_no_js_errors
    end

    it "hides after the silence delay when no 'done' arrives" do
      page.execute_script("document.getElementById('progress-strip').setAttribute('data-progress-strip-silence-delay-value', '300')")
      tick('D', 1, 'D one')
      expect(page).to have_css(message, text: 'D one')
      expect(page).to have_css(panel, visible: :hidden, wait: 3)
      expect_no_js_errors
    end
  end

  it 'asks before the Rescan of the step menu rebuilds: dismissed, nothing happens; accepted, the step is rebuilt' do
    phase4_path = File.join(work_dir, "#{basename}-phase4.json")
    visit_step(4)
    before = file_state(phase4_path)

    find_by_id('data-fix-step-menu-4').click
    dismiss_confirm { find_by_id('data-fix-step-rescan').click }
    expect_still('ul.nav-tabs .nav-link.active', text: 'Step 4')
    expect(page).to have_no_current_path(/rescan=/)
    expect(file_state(phase4_path)).to eq(before)

    find_by_id('data-fix-step-menu-4').click
    accept_confirm { find_by_id('data-fix-step-rescan').click }
    expect(page).to have_css('#flash-messages-container .toast', wait: 15) # (the "phase rebuilt" notice)
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 4')
    expect(page).to have_no_current_path(/rescan=/)
    expect(file_state(phase4_path)).not_to eq(before)
    expect_no_js_errors
  end

  it "shows the progress of a real rebuild of a step and ends hidden on its 'done', with the page usable" do
    visit_step(2)
    tick_until_shown # (the subscription is live)

    find_by_id('data-fix-step-menu-2').click
    accept_confirm { find_by_id('data-fix-step-rescan').click }
    expect(page).to have_css("#{shown_panel} [data-progress-strip-target='scope']", text: basename, wait: 15)

    # (the build maps the 151 teams of the fixture: allow it time; the redirected page shows the "rebuilt" notice)
    expect(page).to have_css(panel, visible: :hidden, wait: 90)
    expect(page).to have_css('#flash-messages-container .toast', wait: 30)
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 2')
    expect(page).to have_css(panel, visible: :hidden)
    expect_nothing_modal
    find('ul.nav-tabs a.nav-link', text: 'Step 1').click
    expect(page).to have_css('ul.nav-tabs .nav-link.active', text: 'Step 1')
    expect_no_js_errors
  end
end
