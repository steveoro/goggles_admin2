# frozen_string_literal: true

module Sources
  #
  # = Sources::FileGuard
  #
  # The only way the Sources pages turn a request parameter into a file path: every path must resolve, through
  # File.realpath (symlinks followed), strictly inside the data root ('crawler/data', see Sources.data_root).
  # The same rule as the old calendar CSV check of the Pull page, applied to every file operation and to the rename
  # targets too.
  #
  # Paths are absolute, or relative to the data root ('results.new/262/x.json').
  #
  # == Usage
  #   guard = Sources::FileGuard.new
  #   path = guard.resolve!(params[:path])                # existing file (Pathname, real path)
  #   dest = guard.resolve_target!(params[:new_path])     # path to create (missing; parent inside the root)
  #   guard.relative(path)                                # => 'results.new/262/x.json'
  #
  # Every refusal raises Sources::FileGuard::Refused, whose #reason is one of REASONS (i18n 'sources.files.refused.*').
  #
  class FileGuard
    REASONS = %i[blank missing outside not_a_file not_a_directory exists].freeze

    # A refused path; +reason+ is one of REASONS.
    class Refused < StandardError
      attr_reader :reason

      def initialize(reason, path = nil)
        @reason = reason
        super("#{reason}: #{path}")
      end
    end

    attr_reader :root

    # Shortcut for FileGuard.new.resolve!(path, type:).
    def self.resolve!(path, type: :file)
      new.resolve!(path, type:)
    end

    # - root: the data root (default: Sources.data_root); while it is missing nothing resolves.
    def initialize(root: Sources.data_root)
      @root = begin
        Pathname.new(root).realpath
      rescue SystemCallError
        Pathname.new(root).expand_path
      end
    end

    # Real path (Pathname) of an existing entry inside the root.
    # - type: :file (default), :directory or :any.
    def resolve!(path, type: :file)
      candidate = expand(path)
      real = begin
        candidate.realpath
      rescue SystemCallError
        raise Refused.new(:missing, path)
      end
      raise Refused.new(:outside, path) unless inside?(real)

      check_type!(real, type, path)
      real
    end

    # Path (Pathname) of an entry still to be created inside the root (a rename target): it must not exist, and its
    # nearest existing ancestor must resolve inside the root (so a symlinked folder pointing out is refused too).
    def resolve_target!(path) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      candidate = expand(path)
      raise Refused.new(:exists, path) if candidate.exist? || candidate.symlink?

      ancestor = candidate.ascend.find(&:exist?)
      real_ancestor = ancestor&.realpath
      raise Refused.new(:outside, path) unless real_ancestor && (real_ancestor == root || inside?(real_ancestor))

      target = real_ancestor.join(candidate.relative_path_from(ancestor)).cleanpath
      raise Refused.new(:outside, path) unless inside?(target)

      target
    end

    # True when +path+ resolves to an existing entry inside the root (never raises).
    def allowed?(path, type: :any)
      resolve!(path, type:)
      true
    rescue Refused
      false
    end

    # Path relative to the root (String), for display and links.
    def relative(path)
      pathname = Pathname.new(path)
      pathname = pathname.realpath if pathname.exist?
      pathname.relative_path_from(root).to_s
    end

    # True when the real path +real+ lies strictly inside the root.
    def inside?(real)
      real.to_s.start_with?("#{root}#{File::SEPARATOR}")
    end

    private

    # Absolute, lexically clean Pathname for +path+ (relative paths are taken from the root).
    def expand(path)
      text = path.to_s
      raise Refused.new(:blank, path) if text.strip.empty? || text.include?("\0")

      candidate = Pathname.new(text)
      (candidate.absolute? ? candidate : root.join(candidate)).cleanpath
    end

    def check_type!(real, type, path)
      case type
      when :file then raise Refused.new(:not_a_file, path) unless real.file?
      when :directory then raise Refused.new(:not_a_directory, path) unless real.directory?
      end
    end
  end
end
