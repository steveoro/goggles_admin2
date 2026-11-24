# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::ConfirmationComponent, type: :component do
  include MaintenanceSpecHelpers

  def run(**summary)
    FactoryBot.create(:ops_operation_run, :previewed, summary: { 'confirmation' => 'one_click', 'empty' => false }.merge(summary))
  end

  it 'renders the one-click apply form' do
    preview = run
    render_inline(described_class.new(run: preview, gate: maintenance_gate_result(:ok)))
    form = page.find('form#frm-operation-apply')
    expect(form[:action]).to eq("/operations/runs/#{preview.id}/apply")
    expect(form[:'data-confirmation-level']).to eq('one_click')
    expect(page).to have_button(I18n.t('maintenance.apply.submit'), disabled: false)
    expect(page).to have_no_field('typed_token')
    expect(page).to have_no_field('confirm')
  end

  it 'asks for the checkbox or the typed text, and for the DB sync tick on a warning' do
    render_inline(described_class.new(run: run('confirmation' => 'confirm'), gate: maintenance_gate_result(:warn)))
    expect(page).to have_field('confirm', type: 'checkbox')
    expect(page).to have_field('drift_ack', type: 'checkbox')

    render_inline(described_class.new(run: run('confirmation' => 'typed', 'typed_token' => 'MERGE 1 INTO 2')))
    expect(page).to have_field('typed_token')
    expect(page).to have_text('MERGE 1 INTO 2')
  end

  it 'disables the button on a red DB sync verdict' do
    render_inline(described_class.new(run: run, gate: maintenance_gate_result(:block)))
    expect(page).to have_css('#operation-apply-drift-red')
    expect(page).to have_button(I18n.t('maintenance.apply.submit'), disabled: true)
  end

  it 'links the apply already made instead of the form, and renders nothing for a dry run that cannot be applied' do
    preview = run
    apply = FactoryBot.create(:ops_operation_run, mode: 'apply', parent_run: preview)
    render_inline(described_class.new(run: preview))
    expect(page).to have_no_css('form#frm-operation-apply')
    expect(page).to have_link(href: "/operations/runs/#{apply.id}")
    expect(render_inline(described_class.new(run: run('empty' => true))).to_html).to be_blank
  end
end
