# frozen_string_literal: true

module Sources
  #
  # = Sources::CrawlToastComponent
  #
  # The end-of-crawl toast of a SourceCrawlJob, broadcast to every open page through AppNotificationsChannel (no CSRF
  # token inside: it holds only a link). Success toasts hide themselves; failures stay until closed.
  #
  class CrawlToastComponent < ViewComponent::Base
    # == Params:
    # - status: :done or :failed; label: the crawl label; message: the end message;
    # - files: new file paths; link_path: where "Open" leads (the tab of the first new file, or the crawler tab).
    def initialize(status:, label:, message:, files: [], link_path: nil)
      super()
      @status = status.to_s == 'done' ? :done : :failed
      @label = label
      @message = message
      @files = Array(files)
      @link_path = link_path
    end

    protected

    def done? = @status == :done

    def toast_attributes
      { role: 'alert', 'aria-live' => 'assertive', 'aria-atomic' => 'true', class: done? ? 'text-bg-success' : 'text-bg-danger',
        data: { controller: 'toast', toast_autohide_value: done?.to_s, toast_delay_value: 10_000 } }
    end

    def title
      t("sources.crawl.toast.#{@status}", label: @label)
    end

    def link_label
      @files.any? ? t('sources.crawl.toast.open_file', name: File.basename(@files.first)) : t('sources.crawl.toast.open_crawler')
    end
  end
end
