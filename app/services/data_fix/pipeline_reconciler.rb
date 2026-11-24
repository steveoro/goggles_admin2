# frozen_string_literal: true

module DataFix
  #
  # = DataFix::PipelineReconciler
  #
  # Rebuilder of the Data-Fix pipeline ops rows ('rake ops:rebuild', registered as :data_fix_pipeline in
  # config/initializers/data_fix_pipeline.rb): recomputes Ops::PipelineSource and Ops::PhaseVerdict for every source
  # with phase files under '<data_root>/results.new/<season>/' (SeasonBoard::DiskIndex naming). Reads the phase
  # files only: never builds, rewrites or deletes one (verdicts are computed in memory, the edit markers stay in the
  # files). Ops::CommitReport and Ops::PipelineRun are not rebuildable.
  #
  # Returns { 'sources' => count, 'verdicts' => count, 'errors' => count }.
  #
  class PipelineReconciler
    PHASE_FILE_REGEXP = SeasonBoard::DiskIndex::PHASE_REGEXP

    def self.call(data_root: Outbox.data_root)
      new(data_root:).call
    end

    def initialize(data_root:)
      @data_root = Pathname.new(data_root)
    end

    def call
      counts = { 'sources' => 0, 'verdicts' => 0, 'errors' => 0 }
      return counts unless Ops.available?

      source_paths.each do |source_path|
        pipeline = DataFix::Pipeline.for(source_path, progress: Import::Progress::Null.new, actor: :auto)
        summary = pipeline.summary(refresh: true)
        counts['sources'] += 1
        counts['verdicts'] += summary.verdicts.values.count { |verdict| !verdict.unbuilt? }
      rescue StandardError => e
        counts['errors'] += 1
        Rails.logger.warn("[DataFix::PipelineReconciler] #{source_path}: #{e.class}: #{e.message}")
      end
      counts
    end

    private

    # Working sources (the '<stem>.json' next to '<stem>-phaseN.json') of every season folder of results.new.
    def source_paths
      root = @data_root.join(Outbox::NEW_DIR)
      return [] unless root.directory?

      root.children.select(&:directory?).sort.flat_map do |season_dir|
        stems = season_dir.children.filter_map do |path|
          match = PHASE_FILE_REGEXP.match(path.basename.to_s)
          match[:stem] if match && !SeasonBoard::DiskIndex::SKIPPED_JSON_REGEXP.match?(path.basename.to_s)
        end
        stems.uniq.sort.filter_map do |stem|
          source = season_dir.join("#{stem}.json")
          source.to_s if source.file?
        end
      end
    end
  end
end
