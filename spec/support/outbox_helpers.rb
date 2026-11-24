# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

# Helpers for the SQL Outbox specs: a temporary crawler data root and SQL files under it.
module OutboxHelpers
  # Writes +content+ at <data_root>/<rel_path> (folders created); returns the Pathname.
  def write_sql_file(data_root, rel_path, content = "SELECT 1;\r\n")
    path = Pathname.new(data_root).join(rel_path)
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, content)
    path
  end

  # Creates a registered Ops::SqlScript (and its file, unless +file+ is false) under +data_root+.
  def create_sql_script(data_root, rel_path, content: "SELECT 1;\r\n", file: true, **attributes)
    path = file ? write_sql_file(data_root, rel_path, content) : Pathname.new(data_root).join(rel_path)
    folder = rel_path.split('/')[1]
    defaults = {
      seq: Outbox::Sequence.prefix_of(rel_path) || (Ops::SqlScript.maximum(:seq).to_i + 1),
      rel_path:, filename: File.basename(rel_path), folder:, season_id: Outbox.season_id_for(folder),
      kind: Outbox::Kinds.infer(rel_path, folder:), sha256: Digest::SHA256.hexdigest(content),
      byte_size: file ? path.size : content.bytesize, file_mtime: file ? path.mtime : Time.current,
      state: rel_path.start_with?('results.sent/') ? 'legacy_sent' : 'pending', applied_locally: true
    }
    Ops::SqlScript.create!(defaults.merge(attributes)).tap { |script| script.data_root = data_root }
  end
end

RSpec.configure do |config|
  config.include(OutboxHelpers)
end
