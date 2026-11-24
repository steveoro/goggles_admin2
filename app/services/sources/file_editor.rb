# frozen_string_literal: true

module Sources
  #
  # = Sources::FileEditor
  #
  # The writes of the Sources file manager, on paths already resolved by Sources::FileGuard and allowed by
  # Sources::FilePolicy:
  #
  # - #save!: a JSON file is parsed first (the save is refused with the parser error), then written to a temporary
  #   file and renamed over the original; CSV and TXT are saved as they are (same atomic write). A Data-Fix phase file
  #   ('<base>-phase<N>.json') is marked as an operator edit (DataFix::Pipeline#mark_edited!, action 'file_editor'),
  #   so the automatic builds never overwrite it, and the board summary is dropped; it is refused while a prepare job
  #   (or another build) holds the source lease;
  # - #rename!: moves the file to the target (creating its folder);
  # - #delete!: deletes the file.
  # Every refusal raises Sources::FileEditor::Refused with an operator message.
  #
  class FileEditor
    class Refused < StandardError; end

    PHASE_REGEXP = SeasonBoard::DiskIndex::PHASE_REGEXP

    def initialize(user_id: nil)
      @user_id = user_id
    end

    # Saves +content+ into +path+ (see the class notes). Returns the phase number marked as edited, or nil.
    def save!(path, content)
      path = Pathname.new(path)
      text = content.to_s
      validate_json!(text) if path.extname.casecmp?('.json')
      phase, source_path = phase_file(path)
      refuse_while_leased!(source_path) if phase

      atomic_write(path, text)
      phase && mark_edited(source_path, phase)
    end

    def rename!(path, target)
      FileUtils.mkdir_p(Pathname.new(target).dirname)
      File.rename(path, target)
    end

    def delete!(path)
      File.delete(path)
    end

    private

    def validate_json!(text)
      JSON.parse(text)
    rescue JSON::ParserError => e
      raise Refused, I18n.t('sources.files.edit.invalid_json', error: e.message.truncate(300))
    end

    # [phase number, source path] of a Data-Fix phase file in a results.new season folder, else nil.
    def phase_file(path)
      match = PHASE_REGEXP.match(path.basename.to_s)
      return nil unless match && path.dirname.dirname.basename.to_s == 'results.new'

      [match[:phase].to_i, path.dirname.join("#{match[:stem]}.json").to_s]
    end

    # Phase 10 rule: no edit while a prepare job or another build holds the source lease.
    def refuse_while_leased!(source_path)
      row = Ops.safely do
        next unless Ops.available?

        Ops::PipelineSource.find_by(season_id: Ops::PipelineSource.season_id_for(source_path), base: Ops::PipelineSource.base_for(source_path))
      end
      return unless row&.lease_owner.present? && row.lease_expires_at.present? && row.lease_expires_at > Time.current

      raise Refused, I18n.t('pipeline_automation.review.edit_refused')
    end

    def atomic_write(path, text)
      temp = path.dirname.join(".#{path.basename}.#{SecureRandom.hex(4)}.tmp")
      File.write(temp, text)
      File.rename(temp, path)
    ensure
      FileUtils.rm_f(temp) if temp && File.exist?(temp)
    end

    # Stamps the operator edit on the saved phase file (it rewrites the file with the edit marker in '_meta').
    def mark_edited(source_path, phase)
      DataFix::Pipeline.for(source_path, progress: Import::Progress::Null.new, user_id: @user_id).mark_edited!(phase, action: 'file_editor')
      SeasonBoard::Snapshot.invalidate!(Ops::PipelineSource.season_id_for(source_path))
      phase
    end
  end
end
