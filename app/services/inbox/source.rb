# frozen_string_literal: true

module Inbox
  #
  # = Inbox::Source
  #
  # Base class of the dashboard inbox sources (registered in Inbox::Registry, see config/initializers/inbox.rb).
  #
  # == Interface (phases 06, 07 and 10 add their own sources)
  # - self.key => Symbol (default: the class name without its namespace, underscored: Sources::PendingSql => :pending_sql);
  # - #items(context) => Array of Inbox::Item (context: an Inbox::Context). It must be READ-ONLY and fast:
  #   no remote call, no file or DB write, about 200 ms or less on today's data;
  # - self.enabled?(context) => false to skip the source (default: true);
  # - self.more_path => optional path listing everything the source knows (shown with the "N more" line when
  #   the inbox is capped; default: nil).
  #
  # Errors are contained by Inbox::Builder: a raising source becomes a single band-1 item, never a 500.
  # Helpers for subclasses: #item (Inbox::Item with this source's key), #action (Inbox::Action), #url_helpers.
  #
  class Source
    class << self
      def key
        name.demodulize.underscore.to_sym
      end

      def enabled?(_context)
        true
      end

      def more_path
        nil
      end

      # Shortcut: new.items(context).
      delegate :items, to: :new
    end

    # Returns the Array of Inbox::Item for the context (subclasses must implement it).
    def items(_context)
      raise NotImplementedError, "#{self.class.name}#items"
    end

    protected

    # Builds an Inbox::Item tagged with this source's key.
    def item(**attributes)
      Item.new(source: self.class.key, **attributes)
    end

    # Builds an Inbox::Action.
    def action(label, path, http_method: :get, params: {}, confirm: nil)
      Action.new(label:, path:, http_method:, params:, confirm:)
    end

    def url_helpers
      Rails.application.routes.url_helpers
    end

    # Translation under 'inbox.<source key>.' (e.g. t(:title) => 'inbox.pending_sql.title').
    def t(key, **options)
      I18n.t("inbox.#{self.class.key}.#{key}", **options)
    end

    # Short localized time (operator's local time zone).
    def short_time(time)
      time ? I18n.l(time.localtime, format: :short) : '-'
    end
  end
end
