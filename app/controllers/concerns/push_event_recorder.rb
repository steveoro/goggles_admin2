# frozen_string_literal: true

# = PushEventRecorder
#
# Appends the 'push.uploaded' / 'push.failed' event to the ops log, one per pushed SQL file.
# A failed log write never affects the push (see Ops.safely).
#
module PushEventRecorder
  extend ActiveSupport::Concern

  private

  def record_push_event(file_path, success:, queue_id: nil, error: nil)
    Ops.safely do
      relative = file_path.to_s.split('crawler/').last
      Ops.record_event!(
        kind: success ? 'push.uploaded' : 'push.failed',
        level: success ? 'success' : 'error',
        actor: 'operator',
        season_id: Integer(File.basename(File.dirname(relative)), exception: false),
        subject_type: 'sql_file',
        subject_key: relative,
        data: { 'file' => File.basename(file_path.to_s), 'path' => relative,
                'import_queue_id' => queue_id, 'error' => error&.to_s&.truncate(500) }.compact
      )
    end
  end
end
