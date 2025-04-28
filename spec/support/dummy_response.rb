# frozen_string_literal: true

# = DummyResponse
#
# Faker for RestClient responses, used when doubling APIProxy.
# Allows to set both the response body & the status result.
#
class DummyResponse
  attr_accessor :body, :success

  # Creates a new fake response, specifying the <tt>:body</tt>
  #
  def initialize(body:)
    @body = body
  end

  # Returns an Hash of fake response/result headers, based on body (if it's an array),
  # as if the @body data had been paginated or an empty Hash otherwise.
  def headers
    return {} unless @body.respond_to?(:to_a)

    {
      page: '1',
      per_page: '25',
      total: @body.to_a.size
    }
  end

  # Fake result code: returns always 200.
  def code
    200
  end

  # Overridden helper
  delegate :to_s, to: :@body
end
