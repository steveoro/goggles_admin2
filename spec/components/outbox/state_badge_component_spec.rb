# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Outbox::StateBadgeComponent, type: :component do
  let(:data_root) { Pathname.new(Dir.mktmpdir) }

  after(:each) { FileUtils.rm_rf(data_root) }

  it 'labels a sent script "sent, not verified" and an executed one "executed, outcome not reported"' do
    sent = create_sql_script(data_root, 'results.sent/262/0005-d-lt4.sql', state: 'sent')
    render_inline(described_class.new(script: sent))
    expect(page).to have_css("[data-outbox-state='sent'] .badge.text-bg-info", text: I18n.t('outbox.states.sent'))

    sent.update!(state: 'executed_unreported')
    render_inline(described_class.new(script: sent))
    expect(page).to have_css('.badge.text-bg-success', text: I18n.t('outbox.states.executed_unreported'))
  end

  it 'labels the phase 08 outcomes: applied, failed, deleted on server, withdrawn' do
    script = create_sql_script(data_root, 'results.sent/262/0005-d-lt4.sql', state: 'applied')
    { 'applied' => 'text-bg-success', 'failed' => 'text-bg-danger', 'missing_remote' => 'text-bg-warning',
      'withdrawn' => 'bg-body-tertiary' }.each do |state, css|
      script.update!(state:)
      render_inline(described_class.new(script:))
      expect(page).to have_css("[data-outbox-state='#{state}'] .badge.#{css.split.first}", text: I18n.t("outbox.states.#{state}"))
    end
  end

  it 'shows the held reason and the warnings' do
    held = create_sql_script(data_root, 'results.new/misc/0013-x.sql', state: 'held', held_reason: 'not_applied_locally',
                                                                       changed_after_push: true, single_transaction: false)
    render_inline(described_class.new(script: held))
    expect(page).to have_text(I18n.t('outbox.held_reasons.not_applied_locally'))
    expect(page).to have_text(I18n.t('outbox.changed_after_push'))
    expect(page).to have_text(I18n.t('outbox.not_single_transaction'))
  end
end
