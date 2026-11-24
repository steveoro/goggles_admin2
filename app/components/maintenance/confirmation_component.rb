# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::ConfirmationComponent
  #
  # The "Apply locally and add to Outbox" form of a succeeded dry run (posts to Maintenance::RunsController#apply),
  # with the confirmation the dry run asks for (Maintenance::Confirmation):
  # - one_click: the button alone;
  # - confirm: a required "I have read the dry run" checkbox;
  # - typed: the exact text to type (e.g. "MERGE 12 INTO 34").
  # Plus the DB sync state (Drift::Gate, scope :operation): a warning needs the operator's tick, a red verdict
  # disables the button (the server re-checks everything, and the job checks the gate again before planning).
  # A dry run is applied once: after its apply (even an interrupted one, whose change may already be in the local DB)
  # it shows the apply instead of the form; an interrupted apply links its run page, which offers a new dry run.
  #
  class ConfirmationComponent < ViewComponent::Base
    # == Params
    # - run: the succeeded preview Ops::OperationRun; gate: its Drift::Gate result (nil: not checked).
    def initialize(run:, gate: nil)
      super()
      @run = run
      @gate = gate
      @confirmation = Maintenance::Confirmation.for_run(run)
    end

    def render? = @run.appliable?

    protected

    attr_reader :run, :gate, :confirmation

    def latest_apply
      return @latest_apply if defined?(@latest_apply)

      @latest_apply = run.latest_apply
    end

    # True when the last apply of this dry run was interrupted: this dry run stays consumed, a new one is needed.
    def latest_interrupted? = latest_apply.present? && latest_apply.interrupted?

    def drift_tick? = gate.present? && gate.warn?
    def drift_blocked? = gate.present? && gate.block?

    def submittable? = !drift_blocked? && !run.applied_or_applying?

    def form_options
      { url: helpers.apply_maintenance_run_path(run), method: :post, id: 'frm-operation-apply',
        data: { turbo_frame: '_top', confirmation_level: confirmation.level } }
    end
  end
end
