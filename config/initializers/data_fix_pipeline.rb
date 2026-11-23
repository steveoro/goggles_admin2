# frozen_string_literal: true

# Data-Fix pipeline (phase 09, see DataFix::Pipeline): 'rake ops:rebuild' recomputes the source stages and the phase
# verdicts from the phase files on disk (the commit reports and the pipeline runs are not rebuildable).
Rails.application.config.to_prepare do
  Ops::Rebuilders.register(:data_fix_pipeline, -> { DataFix::PipelineReconciler.call })
end
