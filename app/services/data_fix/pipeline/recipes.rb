# frozen_string_literal: true

module DataFix
  class Pipeline
    #
    # = DataFix::Pipeline::Recipes
    #
    # The five phase builds, moved as they were from the review actions of the Data-Fix controllers
    # (the solvers write the phase file; Phase 5 also stages the results in the data_import_* tables).
    # Each recipe returns a Hash: { notice: optional flash text, stats: optional Hash }.
    #
    # Phase 5 no longer runs Import::Solvers::ResultSolver: Import::Phase5Populator always rewrote its output.
    #
    module Recipes
      module_function

      def build(pipeline, phase)
        send(:"build_phase#{Integer(phase)}", pipeline)
      end

      # Keyword passed to the solvers / populator: always the pipeline's own sink, so that one operation covers the
      # whole build (an interactive request: its Import::Progress::Cable, one +op+ of the progress strip; a job: its
      # Null / Ops sink).
      def progress_option(pipeline)
        { progress: pipeline.progress }
      end

      def build_phase1(pipeline)
        Import::Solvers::Phase1Solver.new(season: pipeline.season)
                                     .build!(source_path: pipeline.source_path, lt_format: pipeline.lt_format)
        {}
      end

      def build_phase2(pipeline)
        Import::Solvers::TeamSolver.new(season: pipeline.season, **progress_option(pipeline))
                                   .build!(source_path: pipeline.source_path, lt_format: pipeline.lt_format)
        {}
      end

      def build_phase3(pipeline)
        Import::Solvers::SwimmerSolver.new(season: pipeline.season, categories_cache: pipeline.categories_cache,
                                           **progress_option(pipeline))
                                      .build!(source_path: pipeline.source_path, lt_format: pipeline.lt_format,
                                              phase1_path: pipeline.phase_path(1), phase2_path: pipeline.phase_path(2))
        {}
      end

      def build_phase4(pipeline)
        Import::Solvers::EventSolver.new(season: pipeline.season)
                                    .build!(source_path: pipeline.source_path, lt_format: pipeline.lt_format,
                                            phase1_path: pipeline.phase_path(1))
        {}
      end

      # Stages the results (data_import_* tables) and writes the Phase 5 program list; then verifies the staged
      # rows that have exactly one perfect match in the DB (DataFix::ResultVerifier).
      def build_phase5(pipeline)
        populator = Import::Phase5Populator.new(
          source_path: pipeline.source_path,
          phase1_path: pipeline.phase_path(1), phase2_path: pipeline.phase_path(2),
          phase3_path: pipeline.phase_path(3), phase4_path: pipeline.phase_path(4),
          **progress_option(pipeline)
        )
        pipeline.progress.call('Populating phase 5...', 0, 100)
        stats = populator.populate!
        verify = DataFix::ResultVerifier.new(source_path: pipeline.source_path, season_id: pipeline.season&.id)
                                        .verify_all!(progress: pipeline.progress)
        {
          notice: "Phase 5 rebuilt. Populated DB: #{stats[:mir_created]} results, #{stats[:laps_created]} laps",
          stats: stats.merge(auto_verify: verify)
        }
      end
    end
  end
end
