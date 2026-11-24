# frozen_string_literal: true

require 'rails_helper'

# Phase 12: the Data-Fix review pages wire their behaviour through Stimulus controllers only (card controllers,
# issue_nav, verify_team, lib/form_fields): no inline event handler, no inline script, no window.DataFix global.
RSpec.describe 'Data-Fix front-end without inline handlers' do # rubocop:disable RSpec/DescribeClass
  let(:folders) { %w[app/views/data_fix app/components/data_fix] }
  let(:files) { folders.flat_map { |folder| Rails.root.glob("#{folder}/**/*").select(&:file?) } }
  # HTML attributes (onclick="...") and their HAML/Ruby hash forms (onclick: ..., 'onclick' => ...)
  let(:inline_handler) { /(?<![\w-])on(?:click|change|submit|input|keyup|keydown|blur|focus)(?:\s*=|:|['"]\s*=>)/ }

  it 'has template files to scan' do
    expect(files).not_to be_empty
  end

  it 'has no inline event handler under the Data-Fix views and components' do
    hits = files.flat_map do |file|
      file.readlines.each_with_index.filter_map { |line, index| "#{file.relative_path_from(Rails.root)}:#{index + 1}" if line.match?(inline_handler) }
    end
    expect(hits).to be_empty, "inline handlers: #{hits.join(', ')}"
  end

  it 'has no inline script block under the Data-Fix views and components' do
    hits = files.select { |file| file.read.match?(/^\s*:javascript\b|<script\b/) }.map { |file| file.relative_path_from(Rails.root).to_s }
    expect(hits).to be_empty, "inline scripts: #{hits.join(', ')}"
  end

  it 'no longer ships data_fix_helpers.js nor the window.DataFix global' do
    expect(Rails.root.join('app/javascript/data_fix_helpers.js')).not_to exist
    expect(Rails.root.join('config/importmap.rb').read).not_to include('data_fix_helpers')
    js_sources = Rails.root.glob('app/javascript/**/*.js').map(&:read)
    expect(js_sources.grep(/window\.DataFix\b/)).to be_empty
  end
end
