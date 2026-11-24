# frozen_string_literal: true

module Inbox
  #
  # = Inbox::ItemComponent
  #
  # One "Needs you" entry (any Inbox::Item kind): band icon, title (with the group count), detail, how long it has
  # been waiting, and its one primary action button (plus the optional secondary action as a small link button).
  #
  class ItemComponent < ViewComponent::Base
    # Band => [icon, icon colour class, primary button classes]
    BAND_STYLES = {
      blocked: ['fa-ban', 'text-danger', 'btn btn-sm btn-danger'],
      failed: ['fa-circle-exclamation', 'text-danger', 'btn btn-sm btn-outline-danger'],
      push: ['fa-upload', 'text-warning-emphasis', 'btn btn-sm btn-warning'],
      review: ['fa-pen-to-square', 'text-primary', 'btn btn-sm btn-primary'],
      acquire: ['fa-download', 'text-info-emphasis', 'btn btn-sm btn-outline-primary'],
      notice: ['fa-bell', 'text-body-secondary', 'btn btn-sm btn-outline-secondary']
    }.freeze

    # == Params:
    # - item: the Inbox::Item;
    # - now: reference time for the "waiting since" text.
    def initialize(item:, now: Time.current)
      super()
      @item = item
      @now = now
    end

    protected

    attr_reader :item

    def icon = BAND_STYLES.fetch(item.band)[0]
    def icon_css = BAND_STYLES.fetch(item.band)[1]
    def button_css = BAND_STYLES.fetch(item.band)[2]

    def item_data
      { inbox_key: item.key, inbox_band: item.band, inbox_kind: item.kind, inbox_source: item.source }
    end

    def band_label
      t("inbox.bands.#{item.band}")
    end

    # "waiting since 3 days" (relative), or the date for a future time.
    def since_text
      return l(item.since.localtime, format: :short) if item.since > @now

      t('inbox.waiting', ago: helpers.distance_of_time_in_words(item.since, @now, include_seconds: false))
    end

    def since_title
      l(item.since.localtime, format: :long)
    end
  end
end
