# frozen_string_literal: true

# PhaseFileManager: read/write helper for phase-focused JSON files used by the
# new Data-Fix pipeline. Each phase file contains only the minimal data
# necessary for a given review phase plus some metadata for dependency checks.
#
# File shape:
# {
#   "_meta": {
#     "schema_version": "1.0",
#     "generator": "Phase1Solver",
#     "created_at": "2025-09-15T00:00:00Z",
#     "source_path": "/abs/path/to/original.json",
#     "parent_checksum": "<sha256 of parent file>",
#     "dependencies": {
#       "phase2": { "path": "...", "checksum": "..." }
#     }
#   },
#   "data": { ... phase-specific payload ... }
# }
#
class PhaseFileManager
  META_KEY = '_meta'
  DATA_KEY = 'data'

  def initialize(path)
    @path = path
  end

  attr_reader :path

  def read
    return { META_KEY => {}, DATA_KEY => {} } unless File.exist?(path)

    JSON.parse(File.read(path))
  end

  def write!(data:, meta: {})
    payload = { META_KEY => default_meta.merge(meta), DATA_KEY => data }
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(payload))
    payload
  end

  def data
    read[DATA_KEY] || {}
  end

  def meta
    read[META_KEY] || {}
  end

  # Minimal dependency check placeholder (expand later):
  def dependencies_satisfied?
    deps = meta.fetch('dependencies', {})
    return true if deps.blank?

    deps.all? do |_k, h|
      dep_path = h['path']
      dep_checksum = h['checksum']
      next false if dep_path.blank? || dep_checksum.blank?

      File.exist?(dep_path) && checksum(dep_path) == dep_checksum
    end
  end

  def checksum(target_path = path)
    require 'digest'
    Digest::SHA256.hexdigest(File.read(target_path))
  end

  private

  def default_meta
    {
      'schema_version' => '1.0',
      'created_at' => Time.now.utc.iso8601
    }
  end
end
