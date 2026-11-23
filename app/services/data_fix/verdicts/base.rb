# frozen_string_literal: true

module DataFix
  module Verdicts
    #
    # = DataFix::Verdicts::Base
    #
    # Common parent of the phase checkers: subclasses implement #check (filling +issues+, +counts+ and
    # +new_entities+); #call wraps them into a DataFix::Verdict.
    #
    class Base
      PHASE = nil

      attr_reader :pipeline, :issues, :counts, :new_entities

      def initialize(pipeline)
        @pipeline = pipeline
        @issues = []
        @counts = {}
        @new_entities = {}
      end

      def call
        check
        Verdict.build(phase: self.class::PHASE, status: Verdict.status_for(issues), issues:, counts:, new_entities:)
      end

      protected

      def check
        raise NotImplementedError
      end

      def data
        @data ||= pipeline.phase_data(self.class::PHASE)
      end

      def meta
        @meta ||= pipeline.phase_meta(self.class::PHASE)
      end

      # Adds an issue (count 0 is skipped).
      def issue!(code, level, message: nil, count: 1, details: nil)
        return if count.to_i <= 0

        row = { 'code' => code.to_s, 'level' => level.to_s, 'message' => message, 'count' => count.to_i }
        row['details'] = Array(details).first(20) if details.present?
        issues << row.compact
      end

      def blocked!(code, **options)
        issue!(code, :blocked, **options)
      end

      def review!(code, **options)
        issue!(code, :review, **options)
      end

      def info!(code, **options)
        issue!(code, :info, **options)
      end

      # True when the operator saved this phase (or the file pre-existed: adopted files count as saved).
      def operator_saved?
        meta['operator_edit'].present? || pipeline.adopted?(self.class::PHASE)
      end
    end
  end
end
