# frozen_string_literal: true

#
# = FlashAlertComponent
#
# Render a dismissable flash message as a Bootstrap 5 toast
#
class FlashAlertComponent < ViewComponent::Base
  # Supported flash items
  SUPPORTED_SYMS = %i[error warning alert info notice].freeze

  # Creates a new ViewComponent.
  #
  # == Params:
  # - symbol: the flash symbol that will set the alert theme (:info, :notice, :alert, :warning, :error)
  # - title: an additional text title (can be +nil+)
  # - body: the actual text body of the message
  # - sticky: when true adds a CSS marker and disables the toast auto-hide
  def initialize(symbol:, body:, title: nil, sticky: false)
    super()
    @symbol = symbol
    @title = title
    @body = body
    @sticky = ActiveModel::Type::Boolean.new.cast(sticky)
  end

  # Skips rendering unless both :symbol & :body are valid
  def render?
    SUPPORTED_SYMS.include?(@symbol) && @body.to_s.present?
  end

  protected

  # Returns the Bootstrap 5 toast color helper depending on @symbol value
  def alert_background_class
    case @symbol
    when :error
      'text-bg-danger'
    when :warning, :alert
      'text-bg-warning'
    when :info
      'text-bg-info'
    when :notice
      'text-bg-secondary'
    end
  end

  # Errors & sticky payloads must be dismissed manually
  def autohide?
    @symbol != :error && !@sticky
  end

  # Returns the icon CSS depending on @symbol value
  def alert_title_class
    case @symbol
    when :error
      'fa-exclamation-triangle'
    when :warning
      'fa-exclamation-circle'
    else
      'fa-info-circle'
    end
  end

  def alert_css_classes
    ['flash-alert', alert_background_class, (@sticky ? 'flash-sticky' : nil)].compact.join(' ')
  end
end
