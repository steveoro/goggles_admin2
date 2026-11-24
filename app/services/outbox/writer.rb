# frozen_string_literal: true

require 'digest'
require 'securerandom'

module Outbox
  #
  # = Outbox::Writer
  #
  # The single way to create an SQL script waiting to be pushed: every producer (Data-Fix commit, Season board
  # calendar link & backfill, team managers, rake tasks, ...) calls #write! exactly where it used to call
  # File.write (inside its own MySQL transaction, with #discard! in the rescue when the transaction rolls back
  # after the write).
  #
  # #write! allocates the global sequence number (Outbox::Sequence), writes
  # <tt><data_root>/results.new/<folder>/<%04d seq>-<name>.sql</tt> atomically (temporary file + rename), hashes
  # it and registers the Ops::SqlScript row through Ops.safely: with the ops DB missing the file is written all
  # the same (an UnregisteredScript is returned) and Outbox::Reconciler adopts it later.
  #
  # The +sql+ text is written verbatim, so each producer keeps its exact bytes.
  #
  # == Usage
  #   script = Outbox::Writer.write!(kind: 'calendar_link', name: "calendar_link-#{cal.id}-#{fin_id}", sql: text,
  #                                  folder: season.id.to_s, origin: { producer: 'SeasonBoard::CalendarLinker' })
  #   script.absolute_path   # => Pathname of the written file
  #   Outbox::Writer.discard!(script)                 # the local transaction rolled back: file & row deleted
  #   Outbox::Writer.mark_applied_locally!(path)      # a held script was run locally (db:run, simulate=0)
  #
  class Writer
    FOLDER_REGEXP = /\A[\w.-]+\z/

    # Stand-in for Ops::SqlScript returned when the row could not be registered (ops DB missing or failing).
    UnregisteredScript = Data.define(:seq, :rel_path, :filename, :folder, :kind, :season_id, :state, :data_root) do
      def absolute_path = Pathname.new(data_root).join(rel_path)
      def persisted? = false
      def held? = state == 'held'
      def pending? = state == 'pending'
    end

    class << self
      # Writes and registers a new script. Returns the Ops::SqlScript (or an UnregisteredScript).
      #
      # == Params
      # - kind: one of Outbox::Kinds::ALL; name: file name without the 'NNNN-' prefix and the '.sql' extension;
      # - sql: the exact file contents; folder: '<season_id>' or 'misc' (subfolder of results.new);
      # - season_id: default from a numeric folder; origin: JSON-able Hash (producer, ids, rake args, ...);
      # - applied_locally: false for a script not (yet) run on the local DB: it starts held ('not_applied_locally');
      # - held: true to start held anyway (+held_reason+, default 'not_applied_locally' or 'operator');
      # - data_root: crawler data folder; prefix: explicit file number (a rake 'index=' option), seq is allocated anyway.
      #
      def write!(kind:, name:, sql:, folder:, season_id: nil, applied_locally: true, held: false, origin: {}, # rubocop:disable Metrics/ParameterLists,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
                 data_root: Outbox.data_root, prefix: nil, held_reason: nil)
        validate!(kind, name, folder)
        root = Pathname.new(data_root)
        seq = Sequence.next!(data_root: root)
        filename = "#{format('%04d', (prefix || seq).to_i)}-#{clean_name(name)}.sql"
        path = write_file(root.join(Outbox::NEW_DIR, folder.to_s), filename, sql.to_s)

        held = true if applied_locally == false
        attributes = {
          seq:, rel_path: Outbox.relative_path(path, data_root: root), filename:, folder: folder.to_s,
          season_id: season_id || Outbox.season_id_for(folder), kind: kind.to_s,
          sha256: Digest::SHA256.hexdigest(sql.to_s), byte_size: path.size, file_mtime: path.mtime,
          state: held ? 'held' : 'pending',
          held_reason: if held
                         held_reason || (applied_locally ? 'operator' : 'not_applied_locally')
                       end,
          applied_locally:, single_transaction: Kinds.single_transaction?(sql), origin: (origin || {}).deep_stringify_keys
        }
        register(attributes, root)
      end

      # Deletes the file and the row of a script whose producer transaction rolled back after #write!.
      # Never raises; returns nil.
      def discard!(script)
        return if script.nil?

        FileUtils.rm_f(script.absolute_path)
        Ops.safely { script.destroy! if script.is_a?(Ops::SqlScript) && script.persisted? }
        nil
      end

      # Marks the script at +path_or_script+ as applied on the local DB. A script held because it was not applied
      # (or because its local apply failed) goes back to pending and, when other scripts were allocated meanwhile,
      # gets the next seq (its 'NNNN-' prefix renamed while still in results.new) so that it is pushed in
      # local-apply order. A script whose producer asked for a hold after the local apply (origin
      # 'held_after_local_apply', e.g. the standard timings until the remote season exists, phase 13) stays held
      # with that reason instead. Returns the Ops::SqlScript, or nil when it is not registered (or ops is not available).
      def mark_applied_locally!(path_or_script, data_root: Outbox.data_root)
        script = find_script(path_or_script, data_root)
        return if script.nil?

        Ops.safely do
          if script.held? && (script.held_reason.nil? || %w[not_applied_locally local_apply_failed].include?(script.held_reason))
            resequence!(script)
            hold = script.origin.to_h['held_after_local_apply'].presence
            script.update!(applied_locally: true, state: hold ? 'held' : 'pending', held_reason: hold, last_error: nil)
          else
            script.update!(applied_locally: true)
          end
          script
        end
      end

      # Marks a failed local apply: the script stays (or goes) held with reason 'local_apply_failed'.
      def mark_apply_failed!(path_or_script, error:, data_root: Outbox.data_root)
        script = find_script(path_or_script, data_root)
        return if script.nil?

        Ops.safely do
          script.update!(state: script.needs_push? ? 'held' : script.state, held_reason: 'local_apply_failed',
                         applied_locally: false, last_error: error.to_s)
          script
        end
      end

      # The registered Ops::SqlScript for an absolute/relative path (or the given script), or nil.
      def find_script(path_or_script, data_root = Outbox.data_root)
        return path_or_script if path_or_script.is_a?(Ops::SqlScript)
        return if path_or_script.is_a?(UnregisteredScript)

        Ops.safely do
          next unless Ops.available?

          rel_path = Outbox.relative_path(path_or_script, data_root:)
          Ops::SqlScript.find_by(rel_path:)&.tap { |row| row.data_root = data_root }
        end
      end

      # Gives the script the next seq when a higher one exists (renaming its auto-numbered prefix in results.new).
      # Also used by Outbox::ScriptActions.release! for the holds released with a new seq (phase 13).
      def resequence!(script) # rubocop:disable Metrics/AbcSize
        root = script.data_root
        return if Sequence.current_max(data_root: root) <= script.seq

        old_seq = script.seq
        old_name = script.filename
        new_seq = Sequence.next!(data_root: root)
        attributes = { seq: new_seq }
        if script.in_new_dir? && Sequence.prefix_of(old_name) == old_seq && script.file_exists?
          new_name = old_name.sub(Sequence::PREFIX_REGEXP, "#{format('%04d', new_seq)}-")
          new_path = script.absolute_path.dirname.join(new_name)
          File.rename(script.absolute_path, new_path) unless new_path.exist?
          attributes[:filename] = new_name
          attributes[:rel_path] = Outbox.relative_path(new_path, data_root: root)
        end
        script.update!(attributes)
        Ops.record_event!(kind: 'outbox.resequenced', season_id: script.season_id, subject_type: 'sql_script',
                          subject_key: script.id, data: { 'from' => old_name, 'to' => script.filename,
                                                          'old_seq' => old_seq, 'new_seq' => new_seq })
      end

      private

      def validate!(kind, name, folder)
        raise ArgumentError, "unknown Outbox kind '#{kind}'" unless Kinds.valid?(kind)
        raise ArgumentError, 'a script name is required' if clean_name(name).blank?
        raise ArgumentError, "invalid script name '#{name}'" if clean_name(name).include?('/')
        raise ArgumentError, "invalid folder '#{folder}'" if !FOLDER_REGEXP.match?(folder.to_s) || folder.to_s == Outbox::DISCARDED_DIR
      end

      def clean_name(name)
        name.to_s.strip.delete_suffix('.sql')
      end

      # Atomic write (temporary file + rename in the same folder); never overwrites an existing file.
      def write_file(dir, filename, sql)
        Outbox.guard_test_path!(dir)
        FileUtils.mkdir_p(dir)
        path = dir.join(filename)
        raise Outbox::Error, "'#{path}' already exists" if path.exist?

        tmp_path = dir.join(".#{filename}.#{SecureRandom.hex(4)}.tmp")
        File.write(tmp_path, sql) # (as every producer did: same bytes)
        File.rename(tmp_path, path)
        path
      ensure
        FileUtils.rm_f(tmp_path) if tmp_path && File.exist?(tmp_path)
      end

      def register(attributes, root)
        row = Ops.safely do
          next unless Ops.available?

          Ops::SqlScript.create!(attributes).tap { |script| script.data_root = root }
        end
        row || UnregisteredScript.new(**attributes.slice(:seq, :rel_path, :filename, :folder, :kind, :season_id, :state),
                                      data_root: root)
      end
    end
  end
end
