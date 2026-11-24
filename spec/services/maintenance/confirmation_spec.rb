# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Confirmation do
  it 'needs nothing for one click, the checkbox for confirm, the exact text for typed' do
    expect(described_class.new(level: 'one_click', token: nil).satisfied_by?({})).to be(true)
    confirm = described_class.new(level: 'confirm', token: nil)
    expect(confirm.satisfied_by?({})).to be(false)
    expect(confirm.satisfied_by?(confirm: '1')).to be(true)
    typed = described_class.new(level: 'typed', token: 'MERGE 1 INTO 2')
    expect(typed.satisfied_by?(typed_token: 'merge 1 into 2')).to be(false)
    expect(typed.satisfied_by?(typed_token: ' MERGE 1 INTO 2 ')).to be(true)
    expect(described_class.new(level: 'typed', token: nil).satisfied_by?(typed_token: '')).to be(false)
  end

  it 'reads the level and the token stored by the dry run' do
    run = FactoryBot.build(:ops_operation_run, summary: { 'confirmation' => 'typed', 'typed_token' => 'DEDUPE 9' })
    expect(described_class.for_run(run)).to have_attributes(level: 'typed', token: 'DEDUPE 9')
  end
end
