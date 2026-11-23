# frozen_string_literal: true

# rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration, RSpec/BeforeAfterAll, Metrics/AbcSize, RSpec/DescribeClass

require 'rails_helper'

# = Bootstrap 4 burn-down guard =
#
# Counts the Bootstrap 4 leftovers (class names and data-* attributes served by the temporary
# compat layer: app/assets/stylesheets/compat/_bs4.scss + app/javascript/bs4_compat.js) per folder.
# - BASELINE is a ratchet: a folder may never exceed its count. Lower it whenever a folder improves.
# - SWEPT lists the folders (path prefixes) that must have ZERO uses. Phases 04, 05, 07, 12 and 15
#   add their folders here when they go native.
# The per-folder table is printed on every run.
RSpec.describe 'Bootstrap 4 leftovers' do
  ROOTS = %w[app/views app/components app/javascript app/helpers app/grids].freeze
  EXCLUDED = %w[app/javascript/bs4_compat.js].freeze

  # Folders that must have no BS4 token at all (path prefixes):
  SWEPT = %w[app/components/shell app/views/layouts app/views/shell].freeze

  # Current number of tokens per folder (see #folder_key for the grouping):
  BASELINE = {
    'app/views/data_fix' => 292,
    'app/views/api_issues' => 56,
    'app/views/pull' => 34,
    'app/components/season_board' => 23,
    'app/views/goggles_cup' => 20,
    'app/javascript/controllers' => 18,
    'app/components/grid' => 15,
    'app/views/file_list' => 15,
    'app/views/stats' => 14,
    'app/components/issue' => 12,
    'app/views/season_board' => 12,
    'app/components/data_fix' => 11,
    'app/views/api_trainings' => 11,
    'app/views/pdf' => 11,
    'app/views/best_results' => 6,
    'app/views/home' => 6,
    'app/components/combo_box' => 5,
    'app/views/devise' => 5,
    'app/components' => 3,
    'app/views/api_categories' => 4,
    'app/views/datagrid' => 3,
    'app/components/switch' => 2,
    'app/views/api_meeting_reservations' => 2,
    'app/views/api_meetings' => 2,
    'app/views/settings' => 2,
    'app/views/api_team_managers' => 1
  }.freeze

  # Regex choices (each token is anchored so that it can't match inside a longer word or class):
  # - `(?<![\w-])` / `(?![\w-])` bound a class name: no `ml-` inside `html-`, `mr-` inside `lamr-`, no `text-left` inside
  #   `btn-text-left`, no `form-group` inside `form-group-lg`... (BS5 `me-*`/`ms-*`, `text-start/end` never match).
  # - spacing: m/p + l/r, optional breakpoint infix, size 0-5 or auto (margins only, but `pl-auto` doesn't exist anyway).
  # - data-*: only the BS4 names. `data-bs-*` and Stimulus `data-<name>-target` don't match because the name must
  #   directly follow `data-`. The intentional app-level `data-target` of `.verify-team-btn` is counted on purpose:
  #   it is part of the copy-never-move contract and goes away with phase 12.
  # - HAML/Ruby hash keys `toggle:`, `dismiss:`, `placement:` (as in `data: { toggle: 'tooltip' }`); `target:` is
  #   NOT scanned as a key because it's too common as a Stimulus/Rails option.
  CLASS_BOUNDARY_START = '(?<![\w-])'
  CLASS_BOUNDARY_END = '(?![\w-])'
  BREAKPOINT = '(?:-(?:sm|md|lg|xl))?'
  COLORS = '(?:primary|secondary|success|danger|warning|info|light|dark)'
  TOKEN_REGEX = Regexp.union(
    /#{CLASS_BOUNDARY_START}(?:m[lr]|p[lr])#{BREAKPOINT}-(?:[0-5]|auto)#{CLASS_BOUNDARY_END}/,
    /#{CLASS_BOUNDARY_START}text#{BREAKPOINT}-(?:left|right)#{CLASS_BOUNDARY_END}/,
    /#{CLASS_BOUNDARY_START}badge-#{COLORS}#{CLASS_BOUNDARY_END}/,
    /#{CLASS_BOUNDARY_START}form-(?:group|row|inline)#{CLASS_BOUNDARY_END}/,
    /#{CLASS_BOUNDARY_START}btn-group-toggle#{CLASS_BOUNDARY_END}/,
    /#{CLASS_BOUNDARY_START}data-(?:toggle|target|dismiss|parent|placement)#{CLASS_BOUNDARY_END}/,
    /#{CLASS_BOUNDARY_START}(?:toggle|dismiss|placement):/
  )

  # Folder of a file: up to 3 path segments of its directory (app/views/data_fix, app/components/grid,
  # app/javascript/controllers); files right under a root belong to the root (app/components).
  def folder_key(path)
    File.dirname(path).split('/').first(3).join('/')
  end

  def counts_per_folder
    files = ROOTS.flat_map { |root| Dir.glob(Rails.root.join(root, '**', '*').to_s) }
                 .select { |f| File.file?(f) }
                 .map { |f| Pathname.new(f).relative_path_from(Rails.root).to_s }
                 .reject { |f| EXCLUDED.include?(f) }
    files.each_with_object(Hash.new(0)) do |file, memo|
      count = Rails.root.join(file).read.scan(TOKEN_REGEX).size
      memo[folder_key(file)] += count if count.positive?
    end
  end

  let(:counts) { counts_per_folder }

  before(:all) do
    # Printed once, whatever the outcome:
    counts = counts_per_folder
    width = counts.keys.map(&:size).max.to_i
    rows = counts.sort_by { |folder, n| [-n, folder] }.map do |folder, n|
      format("  %-#{width}s  %4d  (baseline %s)", folder, n, BASELINE.fetch(folder, 0))
    end
    swept = SWEPT.empty? ? '(none yet)' : SWEPT.join(', ')
    RSpec.configuration.reporter.message(
      "\nBootstrap 4 leftovers per folder (total #{counts.values.sum}; swept: #{swept}):\n#{rows.join("\n")}\n"
    )
  end

  it 'does not exceed the baseline in any folder' do
    over = counts.select { |folder, n| n > BASELINE.fetch(folder, 0) }
    expect(over).to be_empty, "BS4 leftovers grew (folder => count over baseline): #{over.inspect}"
  end

  it 'has no leftover in the swept folders' do
    used = counts.select { |folder, n| n.positive? && SWEPT.any? { |s| folder == s || folder.start_with?("#{s}/") } }
    expect(used).to be_empty, "BS4 tokens in swept folders: #{used.inspect}"
  end

  it 'only names folders that exist in the baseline and swept lists' do
    expect((BASELINE.keys + SWEPT).reject { |f| Rails.root.join(f).directory? }).to be_empty
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration, RSpec/BeforeAfterAll, Metrics/AbcSize, RSpec/DescribeClass
