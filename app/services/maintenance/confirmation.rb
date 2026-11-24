# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::Confirmation
  #
  # The confirmation an apply needs, decided by the dry run (Maintenance::Operation#confirmation_for):
  # - one_click: the Apply button alone;
  # - confirm: plus the "I have read the dry run" checkbox (param +confirm+ = '1');
  # - typed: plus the exact text of #token typed by the operator (param +typed_token+), e.g. "MERGE 12 INTO 34".
  # Checked by Maintenance::RunsController#apply before the apply run is created.
  #
  Confirmation = Data.define(:level, :token) do
    def self.for_run(run) = new(level: run.confirmation_level.to_s, token: run.typed_token)

    def one_click? = level == 'one_click'
    def confirm? = level == 'confirm'
    def typed? = level == 'typed'

    # True when the request params satisfy the level.
    def satisfied_by?(params)
      case level
      when 'confirm' then params[:confirm].to_s == '1'
      when 'typed' then token.present? && params[:typed_token].to_s.strip == token.to_s
      else true
      end
    end

    # i18n key of the refusal text when not satisfied.
    def error_key = typed? ? 'maintenance.apply.errors.typed_token' : 'maintenance.apply.errors.confirm'
  end
end
