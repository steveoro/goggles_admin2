# frozen_string_literal: true

module Grid
  #
  # = Grid::APIErrorComponent
  #
  # The API error box of a grid page (phase 15): shown in place of the rows when the index call of an api_* page
  # did not answer 200 (see APIGridIndex), instead of bouncing to the dashboard. Shows the code, the error detail
  # (truncated), a Retry link (the same URL) and, for an unreachable server, a link to the API URL in Settings.
  #
  # == Usage (HAML):
  #   = render(Grid::APIErrorComponent.new(error: Grid::APIErrorComponent.error_for(result), retry_path: request.fullpath))
  #
  class APIErrorComponent < ViewComponent::Base
    # DOM id of the box
    DOM_ID = 'grid-api-error'

    # Characters of the error detail shown (an API error page can be a whole HTML document)
    DETAIL_MAX = 400

    # What went wrong: HTTP-like code, best error detail, true when the server could not be reached at all.
    Error = Data.define(:code, :detail, :unreachable) do
      def unreachable? = unreachable
    end

    # Error of an APIProxy::Result (or of a response double answering #code and #body).
    def self.error_for(result)
      detail = result.error_detail if result.respond_to?(:error_detail)
      detail ||= result.body.to_s.presence
      unreachable = result.respond_to?(:unreachable?) && result.unreachable?
      Error.new(code: result.code.to_i, detail: detail.to_s, unreachable:)
    end

    # == Params:
    # - error: a Grid::APIErrorComponent::Error (nothing is rendered when nil);
    # - retry_path: the URL of the Retry link (default: the current request).
    def initialize(error:, retry_path: nil)
      super()
      @error = error
      @retry_path = retry_path
    end

    def render?
      @error.present?
    end

    protected

    def retry_path
      @retry_path || helpers.request.fullpath
    end

    def detail
      @error.detail.to_s.squish.truncate(DETAIL_MAX)
    end
  end
end
