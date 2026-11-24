# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Health::Registry do
  let(:locales) { %i[en it] }
  let(:texts) { %w[title finding howto] }

  it 'has unique keys, known groups and a check class for each group' do
    keys = described_class.all.map(&:key)
    expect(keys).to eq(keys.uniq)
    expect(described_class.all.map(&:group).uniq).to match_array(Ops::HealthRun::GROUPS)
    Ops::HealthRun::GROUPS.each { |group| expect(described_class.group_class(group)).to be < Health::Checks::Base }
  end

  it 'gives every check a title, a finding text and a how-to in en and it, plus at least one way out' do
    described_class::CHECKS.each do |check|
      locales.each do |locale|
        texts.each do |text|
          expect(I18n.t("health.checks.#{check.key}.#{text}", locale:, default: nil)).to be_a(String), "#{locale}: #{check.key}.#{text}"
        end
      end
      # every finding offers a button, a link, a rake command or (always) the how-to text:
      expect(check.rake.present? || check.actions.any? || check.doc.present?).to be(true), check.key
    end
  end

  it 'fills the rake templates and returns nil when an argument is missing' do
    check = described_class.fetch('badges.duplicate.sure')
    expect(check.rake_command('src' => 2, 'dest' => 1)).to eq('bin/rails merge:badge src=2 dest=1 autofix=1')
    expect(check.rake_command('src' => 2)).to be_nil
    expect(described_class.fetch('season.setup').rake_command({})).to be_nil
  end

  it 'returns the check versions of a group' do
    expect(described_class.versions_for('setup')).to eq('season.setup' => 1)
    expect(described_class.stamp_skippable?('results')).to be(true)
    expect(described_class.stamp_skippable?('meetings')).to be(false)
  end
end
