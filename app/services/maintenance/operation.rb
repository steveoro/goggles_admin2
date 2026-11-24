# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::Operation
  #
  # Parent of the maintenance operations (Maintenance::Operations::*, listed by Maintenance::Registry): a fix that can
  # be triggered from the UI, always through the same path (see Maintenance::Executor):
  #   form (prefilled from a health finding) => dry run (#plan, never writes) => apply locally => Outbox => health re-run.
  #
  # == Class attributes
  # - key: stable dotted key ('badge.merge'; stored on Ops::OperationRun, i18n 'maintenance.operations.<key with _>.*');
  # - confirmation: default confirmation level (:one_click, :confirm, :typed; see #confirmation_for);
  # - outbox_kind: Outbox::Kinds value of the script; health_group: Ops::HealthRun group re-run after an apply;
  # - fixes: the Health::Registry check keys whose findings offer this operation (see .offer_for?);
  # - bumps_db_generation: true when an apply changes entities a Data-Fix review may reference (merges, deletions):
  #   the executor then bumps DataFix::Pipeline.db_generation, so the reviews in progress re-check their matches.
  #
  # == Params
  # Declared with .param (name, type :integer | :string | :flag). Flags pass +true+ or +nil+ only to the strategies
  # (Merge::Badge uses .present?, so "0" would count as on): a flag accepts nil, '', true, '1' or 'true' and any
  # other value ("0", "false", ...) is a validation error.
  #
  # == Subclass interface
  # - .params_from_finding(finding) => Hash (String or Symbol keys), the prefilled params;
  # - #build_plan => Maintenance::Plan (called inside Maintenance::OutputCapture: strategies may print);
  # - #file_base => script name without the 'NNNN-' prefix (e.g. "merge_badges-12-34"); may use the state of the
  #   last #plan; #season_id, #subject, #typed_token, #confirmation_for(plan), #follow_ups(plan), #label.
  # - (phase 13) #outbox_folder / #held_reason: where the Executor registers the script (default 'misc', not held);
  #   #after_local_apply(plan): text appended to the run console after a successful local apply (e.g. the post-merge
  #   verification of 'meeting.merge'); #report_progress(done, total, label): progress of a long plan (stored on the
  #   run by the Executor, which also raises Maintenance::Cancelled there when the operator asked to cancel).
  #
  # == Phase 13 additions
  # - .param(name, type, form: false) declares a param set by the rake callers only (never on the form), and
  #   lookup: (:swimmer, :team, :meeting, :season, :badge) names the local lookup of an id field on the form;
  # - .inspector? (Maintenance::Inspector): a read-only check (dry run only, never an apply nor a script);
  # - .cancellable: the run page offers "Cancel" while a run of the operation is pending;
  # - #captured_output: what the strategies printed during the last #plan (the rake callers print it as it was).
  #
  class Operation
    include ActiveModel::Model
    include ActiveModel::Attributes

    CONFIRMATIONS = %i[one_click confirm typed].freeze
    FLAG_VALUES = [nil, '', true, '1', 'true'].freeze
    TRUE_FLAGS = [true, '1', 'true'].freeze

    # A form field: name (Symbol), type (:integer, :string, :flag), form (false: rake only), lookup (domain or nil).
    Field = Data.define(:name, :type, :form, :lookup) do
      def initialize(name:, type:, form: true, lookup: nil) = super
      def form? = form
    end

    class_attribute :key, :outbox_kind, :health_group, instance_writer: false
    class_attribute :confirmation, default: :one_click, instance_writer: false
    class_attribute :fixes, default: [].freeze, instance_writer: false
    class_attribute :fields, default: [].freeze, instance_writer: false
    class_attribute :bumps_db_generation, default: false, instance_writer: false
    class_attribute :cancellable, default: false, instance_writer: false

    # Callable (done, total, label) set by the Executor for #report_progress (it may raise Maintenance::Cancelled).
    attr_writer :progress_reporter

    # What the strategies printed during the last #plan (nil before it); the strategy error it turned into a plan
    # error (nil when none).
    attr_reader :captured_output, :plan_exception

    class << self
      # Declares a param (attribute + form field; +form: false+ for a rake-only param, +lookup:+ for an id field).
      def param(name, type = :integer, form: true, lookup: nil)
        case type
        when :integer then attribute(name, :integer)
        when :string then attribute(name, :string)
        when :flag
          attribute(name)
          validates(name, inclusion: { in: FLAG_VALUES, message: ->(*) { I18n.t('maintenance.errors.invalid_flag') } })
        else raise ArgumentError, "unknown param type #{type.inspect}"
        end
        self.fields = (fields + [Field.new(name: name.to_sym, type:, form:, lookup:)]).freeze
      end

      def param_names = fields.map(&:name)

      # The fields shown on the operation form.
      def form_fields = fields.select(&:form?)

      # True for a read-only inspector (Maintenance::Inspector).
      def inspector? = false

      # True for an operation opened only from the season-start checklist (no form link on /operations).
      def checklist_only? = false

      # True for an operation fixing a whole season (its button also sits on the health section of the check).
      def season_wide? = false

      # 'badge.merge' => 'badge_merge' (i18n key).
      def i18n_key = key.to_s.tr('.', '_')
      def title = I18n.t("maintenance.operations.#{i18n_key}.title")
      def description = I18n.t("maintenance.operations.#{i18n_key}.description")

      # Text of the Fix button on a finding.
      def fix_label = I18n.t("maintenance.operations.#{i18n_key}.fix_label", default: title)

      # The operation prefilled from a health finding (Ops::HealthFinding).
      def from_finding(finding)
        new(**params_from_finding(finding).to_h.symbolize_keys.slice(*param_names))
      end

      def params_from_finding(_finding)
        raise NotImplementedError, "#{name}.params_from_finding"
      end

      # True when a Fix button for this operation belongs on the finding (unresolved, one of the checks it fixes).
      def offer_for?(finding)
        fixes.include?(finding.check_key.to_s) && !finding.resolved?
      end

      # Only the declared form params, from a request (ActionController::Parameters or Hash): the rake-only params
      # (form: false, phase 13) are never taken from a request.
      def permitted(params)
        names = form_fields.map(&:name)
        hash = params.respond_to?(:permit) ? params.permit(*names).to_h : params.to_h
        hash.symbolize_keys.slice(*names)
      end

      def human_attribute_name(attribute, options = {})
        I18n.t("maintenance.params.#{attribute}", default: options[:default] || attribute.to_s.humanize)
      end

      # Payload Hash of a finding (empty for anything else).
      def payload_of(finding)
        finding.payload.is_a?(Hash) ? finding.payload : {}
      end
    end

    # True when the flag param is on.
    def flag?(name) = TRUE_FLAGS.include?(param_value(name))

    # true or nil (never false nor "0"): the value given to the strategies.
    def flag(name) = flag?(name) || nil

    # The params as stored on the run: String keys, flags as true, blank values dropped.
    def to_params
      self.class.fields.each_with_object({}) do |field, hash|
        value = field.type == :flag ? flag(field.name) : param_value(field.name)
        hash[field.name.to_s] = value unless value.nil? || value == ''
      end
    end

    def params_digest = Ops::OperationRun.params_digest_for(to_params)

    # The raw (cast) value of a param, bypassing any reader a subclass overrides (e.g. a derived #season_id).
    def param_value(name) = attributes[name.to_s]

    # The dry run: never writes (primary DB, disk or ops DB). Invalid params or a strategy error (e.g. Merge::Badge's
    # "Unrecoverable errors detected!") give a blocked plan, never an exception. What the strategy printed is kept in
    # the plan console.
    def plan
      return blank_plan(errors: errors.full_messages) unless valid?

      (result, error), console = OutputCapture.capture do
        [build_plan, nil]
      rescue Maintenance::Cancelled
        raise
      rescue StandardError => e
        [nil, e]
      end
      @captured_output = console
      @plan_exception = error
      return blank_plan(errors: [error_text(error)], console:) if error

      result.with(console: [console.presence, result.console.presence].compact.join("\n"))
    end

    # Confirmation level needed to apply +plan+ (:one_click, :confirm, :typed).
    def confirmation_for(_plan) = self.class.confirmation

    # Text the operator must type for a :typed confirmation (nil otherwise).
    def typed_token = nil

    # Script name without the 'NNNN-' prefix and '.sql'.
    def file_base = raise(NotImplementedError, "#{self.class.name}#file_base")

    # Season of the subject (nil when unknown or cross-season).
    def season_id = nil

    # [subject_type, subject_id] stored on the run (nil when none).
    def subject = nil

    # Suggested next operations after an apply: Array of { 'operation_key' =>, 'params' => } (never chained).
    def follow_ups(_plan) = []

    # One-line description of what this run does.
    def label = self.class.title

    # Outbox folder of the script ('misc', or a season id for the season-bound scripts).
    def outbox_folder = Outbox::MISC_FOLDER

    # Held reason of the script registered after a local apply (nil: pending, pushable).
    def held_reason = nil

    # Text appended to the run console after a successful local apply (nil: nothing).
    def after_local_apply(_plan) = nil

    # Progress of a long plan (+done+ of +total+, +label+ text): forwarded to the Executor's reporter, which may raise
    # Maintenance::Cancelled. A no-op without a reporter (rake inspectors, specs).
    def report_progress(done, total, label = nil)
      @progress_reporter&.call(done, total, label)
    end

    protected

    def build_plan = raise(NotImplementedError, "#{self.class.name}#build_plan")

    # A plan with every member defaulted (+overrides+ replace them).
    def blank_plan(**overrides)
      Plan.new(operation_key: key, params: to_params, label: safe { label } || self.class.title, season_id: safe { season_id },
               subjects: [], console: '', summary: {}, warnings: [], errors: [], sql_lines: [],
               health_group: self.class.health_group).with(**overrides)
    end

    # The value of the block, nil on any error (labels and season ids of a plan that could not be built).
    def safe
      yield
    rescue StandardError
      nil
    end

    def error_text(error)
      text = error.message.to_s
      text = "#{error.class}: #{text}" unless error.is_a?(RuntimeError) || error.is_a?(ArgumentError)
      text.truncate(2000)
    end
  end
end
