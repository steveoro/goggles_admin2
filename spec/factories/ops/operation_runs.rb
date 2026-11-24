# frozen_string_literal: true

FactoryBot.define do
  factory :ops_operation_run, class: 'Ops::OperationRun' do
    operation_key { 'meeting.set_cancelled' }
    params { { 'meeting_id' => 19_412 } }
    params_digest { Ops::OperationRun.params_digest_for(params) }
    mode { 'preview' }
    status { 'queued' }
    origin { 'ui' }
    label { 'Flag meeting 19412 cancelled' }

    # A finished, appliable dry run.
    trait :previewed do
      status { 'succeeded' }
      started_at { 1.minute.ago }
      finished_at { Time.current }
      sql_preview { "UPDATE `meetings`\r\n  SET `cancelled`=TRUE, `updated_at`=NOW()\r\n  WHERE `id`=19412;" }
      sql_digest { Digest::SHA256.hexdigest('x') }
      summary { { 'confirmation' => 'one_click', 'empty' => false, 'statements' => 1 } }
    end
  end
end
