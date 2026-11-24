# frozen_string_literal: true

# rubocop:disable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration, RSpec/BeforeAfterAll, Metrics/AbcSize, RSpec/DescribeClass

require 'rails_helper'

# = Bootstrap 4 leftovers guard =
#
# Counts the Bootstrap 4 tokens (class names and data-* attributes that Bootstrap 5 dropped) per folder.
# The app markup, components, helpers, grids, JS and SCSS are native Bootstrap 5 (phase 15 removed the global
# compat layer): every app folder must have ZERO uses (SWEPT).
# The only Bootstrap 4 markup left is in the goggles_db engine GoggleCup partials (shared with goggles_main, still on
# Bootstrap 4), rendered inside the `.goggles-db-partial` wrapper and served by a scoped subset:
# app/assets/stylesheets/compat/_goggles_db_partials.scss (spacing, text alignment, badge colors) and
# app/javascript/controllers/goggles_db_partial_controller.js (data-* copies). Those two files name the tokens they
# serve (EXCLUDED). The engine partials are counted too: BASELINE is a ratchet on them (lower it when the engine
# drops some), and their tokens must stay within what the scoped subset serves.
# The per-folder table is printed on every run.
RSpec.describe 'Bootstrap 4 leftovers' do
  ROOTS = %w[app/views app/components app/javascript app/helpers app/grids app/assets/stylesheets].freeze
  EXCLUDED = %w[app/assets/stylesheets/compat/_goggles_db_partials.scss
                app/javascript/controllers/goggles_db_partial_controller.js].freeze

  # Folders that must have no BS4 token at all (path prefixes): the whole app.
  SWEPT = ROOTS

  # goggles_db engine partials rendered by the app inside `.goggles-db-partial` (folder key => absolute folder):
  ENGINE_FOLDERS = {
    'goggles_db:app/views/goggles_db/goggle_cups' => GogglesDb::Engine.root.join('app/views/goggles_db/goggle_cups')
  }.freeze

  # Current number of tokens per folder (only the engine partials may have some):
  BASELINE = {
    'goggles_db:app/views/goggles_db/goggle_cups' => 16
  }.freeze

  # Regex choices (each token is anchored so that it can't match inside a longer word or class):
  # - `(?<![\w-])` / `(?![\w-])` bound a class name: no `ml-` inside `html-`, `mr-` inside `lamr-`, no `text-left` inside
  #   `btn-text-left`, no `form-group` inside `form-group-lg`... (BS5 `me-*`/`ms-*`, `text-start/end` never match).
  # - spacing: m/p + l/r, optional breakpoint infix, size 0-5 or auto (margins only, but `pl-auto` doesn't exist anyway).
  # - data-*: only the BS4 names. `data-bs-*` and Stimulus `data-<name>-target` don't match because the name must
  #   directly follow `data-`.
  # - HAML/Ruby hash keys `toggle:`, `dismiss:`, `placement:` (as in `data: { toggle: 'tooltip' }`), unless the value
  #   is a boolean: `{ toggle: false }` is the BS5 Collapse option (BS4 data values are strings). `target:` is NOT
  #   scanned as a key because it's too common as a Stimulus/Rails option.
  CLASS_BOUNDARY_START = '(?<![\w-])'
  CLASS_BOUNDARY_END = '(?![\w-])'
  BREAKPOINT = '(?:-(?:sm|md|lg|xl))?'
  COLORS = '(?:primary|secondary|success|danger|warning|info|light|dark)'
  # Tokens served by the scoped subset (CSS: spacing, text alignment, badge colors; JS: the data-* copies):
  SERVED_TOKEN_REGEX = Regexp.union(
    /#{CLASS_BOUNDARY_START}(?:m[lr]|p[lr])#{BREAKPOINT}-(?:[0-5]|auto)#{CLASS_BOUNDARY_END}/,
    /#{CLASS_BOUNDARY_START}text#{BREAKPOINT}-(?:left|right)#{CLASS_BOUNDARY_END}/,
    /#{CLASS_BOUNDARY_START}badge-#{COLORS}#{CLASS_BOUNDARY_END}/,
    /#{CLASS_BOUNDARY_START}data-(?:toggle|target|dismiss|parent|placement)#{CLASS_BOUNDARY_END}/,
    /#{CLASS_BOUNDARY_START}(?:toggle|dismiss|placement):(?!\s*(?:true|false)\b)/
  )
  TOKEN_REGEX = Regexp.union(
    SERVED_TOKEN_REGEX,
    /#{CLASS_BOUNDARY_START}form-(?:group|row|inline)#{CLASS_BOUNDARY_END}/,
    /#{CLASS_BOUNDARY_START}btn-group-toggle#{CLASS_BOUNDARY_END}/
  )

  # Folder of an app file: up to 3 path segments of its directory (app/views/data_fix, app/components/grid,
  # app/javascript/controllers); files right under a root belong to the root (app/components).
  def folder_key(path)
    File.dirname(path).split('/').first(3).join('/')
  end

  # Tokens found in +file+ (the binary files of app/assets are read as text and scrubbed).
  def tokens_in(file)
    File.read(file).scrub.scan(TOKEN_REGEX)
  end

  def counts_per_folder
    files = ROOTS.flat_map { |root| Dir.glob(Rails.root.join(root, '**', '*').to_s) }
                 .select { |f| File.file?(f) }
                 .map { |f| Pathname.new(f).relative_path_from(Rails.root).to_s }
                 .reject { |f| EXCLUDED.include?(f) }
    memo = files.each_with_object(Hash.new(0)) do |file, counts|
      count = tokens_in(Rails.root.join(file)).size
      counts[folder_key(file)] += count if count.positive?
    end
    ENGINE_FOLDERS.each { |key, dir| memo[key] = engine_tokens(dir).size }
    memo
  end

  def engine_tokens(dir)
    Dir.glob(dir.join('**', '*').to_s).select { |f| File.file?(f) }.flat_map { |f| tokens_in(f) }
  end

  let(:counts) { counts_per_folder }

  before(:all) do
    # Printed once, whatever the outcome:
    counts = counts_per_folder
    width = counts.keys.map(&:size).max.to_i
    rows = counts.sort_by { |folder, n| [-n, folder] }.map do |folder, n|
      format("  %-#{width}s  %4d  (baseline %s)", folder, n, BASELINE.fetch(folder, 0))
    end
    RSpec.configuration.reporter.message(
      "\nBootstrap 4 leftovers per folder (total #{counts.values.sum}; swept: #{SWEPT.join(', ')}):\n#{rows.join("\n")}\n"
    )
  end

  it 'does not exceed the baseline in any folder' do
    over = counts.select { |folder, n| n > BASELINE.fetch(folder, 0) }
    expect(over).to be_empty, "BS4 leftovers grew (folder => count over baseline): #{over.inspect}"
  end

  it 'has no leftover in the swept folders (the whole app)' do
    used = counts.select { |folder, n| n.positive? && SWEPT.any? { |s| folder == s || folder.start_with?("#{s}/") } }
    expect(used).to be_empty, "BS4 tokens in swept folders: #{used.inspect}"
  end

  it 'keeps the baseline to the engine partials' do
    expect(BASELINE.keys - ENGINE_FOLDERS.keys).to be_empty
  end

  it 'finds only tokens served by the scoped compat subset in the engine partials' do
    unserved = ENGINE_FOLDERS.values.flat_map { |dir| engine_tokens(dir) }.grep_v(SERVED_TOKEN_REGEX)
    expect(unserved).to be_empty, "engine partial tokens not covered by compat/_goggles_db_partials.scss: #{unserved.uniq}"
  end

  it 'only names folders that exist in the swept and engine lists' do
    expect(SWEPT.reject { |f| Rails.root.join(f).directory? }).to be_empty
    expect(ENGINE_FOLDERS.values.reject(&:directory?)).to be_empty
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock, RSpec/LeakyConstantDeclaration, RSpec/BeforeAfterAll, Metrics/AbcSize, RSpec/DescribeClass
