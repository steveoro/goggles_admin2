# frozen_string_literal: true

require 'rails_helper'

# Every Stimulus controller named in a view, component or helper must exist: Stimulus derives the identifier from the
# file name with dashes (app/javascript/controllers/db_restore_controller.js => 'db-restore'), and an unknown
# identifier fails silently (the element is never connected: e.g. a poller that never polls).
RSpec.describe 'Stimulus controller identifiers' do # rubocop:disable RSpec/DescribeClass
  let(:controllers_dir) { Rails.root.join('app/javascript/controllers') }

  let(:known) do
    Dir.glob(controllers_dir.join('**/*_controller.js')).to_set do |path|
      Pathname.new(path).relative_path_from(controllers_dir).to_s.delete_suffix('_controller.js').tr('_', '-').gsub('/', '--')
    end
  end

  # Literal identifiers of: controller: 'a b' / "a b" (data hashes), 'data-controller': '...' and data-controller="...".
  let(:references) do
    patterns = [/\bcontroller:\s*(['"])([^'"#]+)\1/, /['"]data-controller['"]\s*(?::|=>)\s*(['"])([^'"#]+)\1/,
                /data-controller=(['"])([^'"]+)\1/]
    Rails.root.glob('app/{views,components,helpers}/**/*.{haml,erb,rb}').flat_map do |path|
      text = path.read
      patterns.flat_map { |pattern| text.scan(pattern).map(&:last) }
              .flat_map(&:split).map { |name| [name, path.relative_path_from(Rails.root).to_s] }
    end
  end

  it 'finds some references (the scan works)' do
    expect(references.map(&:first)).to include('live-frames', 'season-board')
  end

  it 'names only existing controllers, with dashes' do
    unknown = references.filter_map { |name, path| "#{path}: #{name}" unless known.include?(name) }
    expect(unknown).to be_empty, "unknown Stimulus identifiers:\n#{unknown.uniq.join("\n")}"
  end
end
