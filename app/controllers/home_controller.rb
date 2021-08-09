# frozen_string_literal: true

require 'version'

# = HomeController
#
# Main landing actions.
#
class HomeController < ApplicationController
  before_action :authenticate_user!

  # [GET] Main landing page default action.
  def index
    # (no-op)
  end
end
