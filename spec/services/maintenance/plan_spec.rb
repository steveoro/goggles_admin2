# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Maintenance::Plan do
  def plan(sql_lines, errors: [])
    described_class.new(operation_key: 'x.y', params: {}, label: 'x', season_id: nil, subjects: [], console: '', summary: {},
                        warnings: [], errors:, sql_lines:, health_group: nil)
  end

  it 'ignores comment and blank lines in the digest, also inside multi-line elements' do
    one = plan(["-- generated #{Time.current}", '', "UPDATE a SET b=1 WHERE id=2;\r\n-- note 1", 'COMMIT;'])
    two = plan(['-- generated later', "\r\n", 'UPDATE a SET b=1 WHERE id=2;', '-- note 2', 'COMMIT;'])
    expect(one.digest).to eq(two.digest)
    expect(plan(['UPDATE a SET b=2 WHERE id=2;', 'COMMIT;']).digest).not_to eq(one.digest)
  end

  it 'is empty without INSERT / UPDATE / DELETE, also when a statement follows a comment in the same element' do
    expect(plan(['SET AUTOCOMMIT = 0;', 'START TRANSACTION;', '-- nothing', 'COMMIT;'])).to be_empty
    hidden = plan(["-- header\r\nDELETE l1 FROM laps l1 WHERE l1.id > 3;"])
    expect(hidden).not_to be_empty
    expect(hidden.write_statements_count).to eq(1)
  end

  it 'is blocked by errors and joins the script with CRLF' do
    expect(plan([], errors: ['no'])).to be_blocked
    expect(plan(%w[A; B;]).sql_text).to eq("A;\r\nB;\r\n")
  end
end
