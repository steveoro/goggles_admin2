# frozen_string_literal: true

# PhaseFileManager: read/write helper for phase-focused JSON files used by the
# new Data-Fix pipeline. Each phase file contains only the minimal data
# necessary for a given review phase plus some metadata (edit markers and input digests: see DataFix::Pipeline).
#
# File shape:
# {
#   "_meta": {
#     "schema_version": "1.0",
#     "generator": "Phase1Solver",
#     "created_at": "2025-09-15T00:00:00Z",
#     "source_path": "/abs/path/to/original.json",
#     "built": { "by": "auto|operator|adopted", "at": "...", "digest": "<sha256 of data>", "inputs": {...} },
#     "operator_edit": { "at": "...", "user_id": 1, "actions": [...] }
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

  # Parsed payload for the file at +path+, memoized so #data/#meta don't
  # re-read and re-parse the same JSON on every call.
  def read
    @read ||=
      if File.exist?(path)
        JSON.parse(File.read(path))
      else
        { META_KEY => {}, DATA_KEY => {} }
      end
  end

  def write!(data:, meta: {})
    # generated_at is always refreshed on write (applied after the merge so a
    # stale value carried over in +meta+ can't survive).
    payload = { META_KEY => default_meta.merge(meta).merge('generated_at' => Time.now.utc.iso8601),
                DATA_KEY => data }
    write_payload!(payload)
  end

  # Writes the whole +payload+ Hash as is (any shape, e.g. the flat Phase 5 file) atomically:
  # a temporary sibling file renamed over the target, so a reader never sees a half-written file.
  def write_payload!(payload)
    FileUtils.mkdir_p(File.dirname(path))
    temporary_path = File.join(File.dirname(path), ".#{File.basename(path)}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")
    File.write(temporary_path, JSON.pretty_generate(payload))
    File.rename(temporary_path, path)
    @read = nil
    payload
  ensure
    FileUtils.rm_f(temporary_path) if temporary_path && File.exist?(temporary_path)
  end

  # SHA256 of the canonical JSON of the phase data ('_meta' excluded; see DataFix::Pipeline::Digests).
  # +phase+ selects the layout: the Phase 5 file is flat (no 'data' section).
  def data_digest(phase: nil)
    phase ||= path[/-phase(\d+)\.json\z/, 1].to_i
    DataFix::Pipeline::Digests.data_digest(read, phase)
  end

  def data
    read[DATA_KEY] || {}
  end

  def meta
    read[META_KEY] || {}
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
