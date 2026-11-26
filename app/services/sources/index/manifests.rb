# frozen_string_literal: true

module Sources
  class Index
    #
    # = Sources::Index::Manifests
    #
    # Rows of the Manifests tab: the manifest PDFs waiting in 'manifests/<season>' (the FIN result crawler downloads
    # them), with their extraction state: queued or running (SeasonBoard::ActivityLog, a board or a Sources
    # extraction), the last failure, and "given up" (three failed automatic attempts, phase 10). The primary action
    # queues one ManifestExtractJob for the file.
    #
    class Manifests
      def initialize(index, engine: nil)
        @index = index
        @engine = engine
      end

      def rows
        @index.files_in('manifests', '*.pdf').map do |path|
          entry = activity_entry(path)
          @index.file_row(path, badges: badges(path, entry), primary: extract_action(path, entry))
        end
      end

      private

      # The latest extraction of the PDF: under its source key (a Sources extraction) or under the FIN event id of its
      # base (the board, the planner, or a Sources extraction of a FIN row's PDF).
      def activity_entry(path)
        fin_event_id = disk_index.fin_event_id_for_base(path.basename('.pdf').to_s.delete_prefix('manifest-'))
        entries = [log.entry(SeasonBoard::ActivityLog.source_key('extract', path.to_s), :extract),
                   (log.entry(fin_event_id, :extract) if fin_event_id)].compact
        entries.find(&:busy?) || entries.max_by { |entry| entry.last_timestamp.to_f }
      end

      def log
        @log ||= SeasonBoard::ActivityLog.new
      end

      def disk_index
        @disk_index ||= SeasonBoard::DiskIndex.new(season_id: @index.season_id, data_dir: @index.data_root)
      end

      def badges(path, entry)
        [
          (Badge.new(label: 'TXT', tone: 'secondary', title: I18n.t('sources.manifests.badges.txt')) if path.sub_ext('.txt').file?),
          activity_badge(entry),
          (Badge.new(label: I18n.t('sources.manifests.badges.gave_up'), tone: 'danger') if gave_up?(path)),
          linked_badge(path)
        ].compact
      end

      # (0.10.104) The meeting of the PDF is already linked locally: "Extract next" leaves it out.
      def linked_badge(path)
        return unless queue.linked_meeting?(path)

        Badge.new(label: I18n.t('sources.manifests.badges.linked'), tone: 'success', title: I18n.t('sources.manifests.badges.linked_tooltip'))
      rescue StandardError
        nil
      end

      def queue
        @queue ||= Sources::ManifestQueue.new(season_id: @index.season_id, data_root: @index.data_root)
      end

      def activity_badge(entry)
        return unless entry
        return Badge.new(label: I18n.t("sources.manifests.badges.#{entry.status}"), tone: 'info') if entry.busy?
        return unless entry.failed?

        Badge.new(label: I18n.t('sources.manifests.badges.failed'), tone: 'danger', title: entry.message.to_s.truncate(200))
      end

      # (only with the ops DB: the planner treats an unreadable count as "gave up", the page just shows nothing)
      def gave_up?(path)
        Ops.available? && SeasonBoard::PipelinePlanner.extraction_gave_up?(path.to_s)
      rescue StandardError
        false
      end

      def extract_action(path, entry)
        RowAction.new(label: I18n.t('sources.manifests.actions.extract'), icon: 'fa-wand-magic-sparkles', http_method: :post,
                      path: @index.url_helpers.sources_manifests_extract_path,
                      params: { pdf_path: @index.relative(path), season_id: @index.season_id, engine: @engine }.compact,
                      disabled: entry&.busy? || false)
      end
    end
  end
end
