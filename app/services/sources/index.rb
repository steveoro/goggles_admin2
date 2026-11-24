# frozen_string_literal: true

module Sources
  #
  # = Sources::Index
  #
  # The rows of the Sources tabs for one season (read-only: every action is a link or a form of the row):
  # - #results:   the sources pending in 'results.new/<season>' (SeasonBoard::DiskIndex: FIN id, LT2/LT4 role, phase
  #               files; DataFix::SessionIndex: staged rows; SeasonBoard::PipelineIndex: the phase 09/10 verdicts);
  # - #pdfs:      the PDFs in 'pdfs/<season>' with their TXT, JSON and scan state;
  # - #calendars: the calendar CSVs in 'calendar.new/<season>' (originals, '-sel-' subsets, '-skip' leftovers) and
  #               'calendar.done/<season>';
  # - #manifests: the manifests pending extraction in 'manifests/<season>'.
  # Each Row has at most one primary action (Prepare, Resume, Open, Select meetings, Extract...); the file actions
  # (edit, rename, delete, Data-Fix) are added by Sources::FileTableComponent from Sources::FilePolicy.
  #
  class Index
    # One listed file. +badges+: Array of Badge; +primary+ / +extra+: RowAction (or nil) / Array of RowAction;
    # +data_fix+: the Data-Fix entry of the file actions menu (nil: none, the primary is already one).
    Row = Data.define(:path, :relative_path, :size, :mtime, :badges, :primary, :extra, :data_fix, :note) do
      def initialize(badges: [], primary: nil, extra: [], data_fix: nil, note: nil, **) = super # rubocop:disable Metrics/ParameterLists

      def name = File.basename(path.to_s)
    end

    # A small label (Bootstrap +tone+: primary, success, warning, danger, info, secondary); +path+ makes it a link.
    Badge = Data.define(:label, :tone, :title, :path) do
      def initialize(tone: 'secondary', title: nil, path: nil, **) = super
    end

    # A row action: a link (http_method :get) or a one-button form (:post, with +params+).
    RowAction = Data.define(:label, :path, :http_method, :params, :icon, :confirm, :disabled, :kind) do
      def initialize(http_method: :get, params: {}, icon: nil, confirm: nil, disabled: false, kind: nil, **) = super # rubocop:disable Metrics/ParameterLists

      def post? = http_method == :post
      def disabled? = disabled
    end

    attr_reader :season_id, :data_root, :guard

    def initialize(season_id:, data_root: Sources.data_root, guard: nil)
      @season_id = season_id.to_i
      @data_root = Pathname.new(data_root)
      @guard = guard || FileGuard.new(root: @data_root)
    end

    def results = Index::Results.new(self).rows

    # Hash of group (:originals, :subsets, :leftovers, :done) => Array of Row.
    def calendars = Index::Calendars.new(self).groups

    def pdfs = Index::Pdfs.new(self).rows

    # - engine: the LLM engine of the "Extract" actions (nil: the default one).
    def manifests(engine: nil) = Index::Manifests.new(self, engine:).rows

    # Number of manifests already extracted for the season ('manifests.done/<season>').
    def done_manifest_count
      files_in('manifests.done', '*.pdf').size
    end

    # Number of SQL scripts waiting in 'results.new/<season>' (listed by the Outbox).
    def sql_count
      files_in('results.new', '*.sql').size
    end

    # == Shared helpers of the tab builders

    def season_dir(folder) = data_root.join(folder, season_id.to_s)

    # Files (Pathnames, sorted) of the season folder matching +glob+ (hidden files left out).
    def files_in(folder, glob)
      dir = season_dir(folder)
      return [] unless dir.directory?

      dir.glob(glob).select(&:file?).reject { |path| path.basename.to_s.start_with?('.') }.sort
    end

    # A Row for an existing file (size and mtime read now).
    def file_row(path, **attributes)
      pathname = Pathname.new(path)
      Row.new(path: pathname.to_s, relative_path: relative(pathname), size: pathname.size, mtime: pathname.mtime, **attributes)
    end

    delegate :relative, to: :guard

    def url_helpers = Rails.application.routes.url_helpers
  end
end
