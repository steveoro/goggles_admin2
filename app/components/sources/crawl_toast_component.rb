# frozen_string_literal: true

module Sources
  #
  # = Sources::CrawlToastComponent
  #
  # The end-of-crawl toast of a SourceCrawlJob, broadcast to every open page through AppNotificationsChannel (no CSRF
  # token inside: it holds only a link). Success toasts hide themselves; warnings (0.10.103: a calendar crawl that brought
  # no usable calendar) and failures stay until closed.
  #
  class CrawlToastComponent < ViewComponent::Base
    STATUSES = %i[done warning failed].freeze
    BACKGROUNDS = { done: 'text-bg-success', warning: 'text-bg-warning', failed: 'text-bg-danger' }.freeze

    # == Params:
    # - status: :done, :warning or :failed (anything else counts as failed); label: the crawl label; message: the end
    #   message;
    # - files: new file paths; link_path: where "Open" leads (the tab of the first new file, or the crawler tab).
    def initialize(status:, label:, message:, files: [], link_path: nil)
      super()
      @status = STATUSES.find { |known| known.to_s == status.to_s } || :failed
      @label = label
      @message = message
      @files = Array(files)
      @link_path = link_path
    end

    protected

    def done? = @status == :done
    def warning? = @status == :warning

    def toast_attributes
      { role: 'alert', 'aria-live' => 'assertive', 'aria-atomic' => 'true', class: BACKGROUNDS.fetch(@status),
        data: { controller: 'toast', toast_autohide_value: done?.to_s, toast_delay_value: 10_000 } }
    end

    # (the dark text of a warning toast needs the dark close button and link)
    def light_text? = !warning?

    def icon = { done: 'fa-spider', warning: 'fa-circle-exclamation', failed: 'fa-triangle-exclamation' }.fetch(@status)

    def title
      t("sources.crawl.toast.#{@status}", label: @label)
    end

    def link_label
      @files.any? ? t('sources.crawl.toast.open_file', name: File.basename(@files.first)) : t('sources.crawl.toast.open_crawler')
    end
  end
end
