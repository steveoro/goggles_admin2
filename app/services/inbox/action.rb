# frozen_string_literal: true

module Inbox
  #
  # = Inbox::Action
  #
  # The one button of an Inbox::Item (rendered by Inbox::ItemComponent):
  # - label: button text (already translated);
  # - path: app path (or a full 'http(s)://' URL for a documentation link, opened in a new tab);
  # - http_method: :get (a link), :post or :delete (a one-button form, see +params+);
  # - params: form fields of a POST/DELETE (Hash; ignored for :get, put them in the path instead);
  # - confirm: optional confirmation text (Turbo confirm dialog).
  #
  # Every action is started by a click and lands on an existing controller action: no inbox action commits,
  # pushes, applies or restores by itself.
  #
  class Action < Data.define(:label, :path, :http_method, :params, :confirm)
    HTTP_METHODS = %i[get post delete].freeze

    def initialize(label:, path:, http_method: :get, params: {}, confirm: nil)
      http_method = http_method.to_s.downcase.to_sym
      raise ArgumentError, "unsupported http_method: #{http_method.inspect}" unless HTTP_METHODS.include?(http_method)
      raise ArgumentError, 'an action needs a label and a path' if label.blank? || path.blank?

      super(label: label.to_s, path: path.to_s, http_method:, params: (params || {}).to_h, confirm: confirm.presence)
    end

    def get? = http_method == :get

    # True for a full URL (e.g. a documentation page), opened in a new tab.
    def external? = path.match?(%r{\Ahttps?://})
  end
end
