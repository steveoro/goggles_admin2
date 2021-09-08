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

  # Overridden helper
  def to_s
    @body.to_s
  end
end
