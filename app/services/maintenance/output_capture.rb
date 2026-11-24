# frozen_string_literal: true

require 'stringio'

module Maintenance
  #
  # = Maintenance::OutputCapture
  #
  # Captures what the maintenance strategies print (checker reports, progress dots) while an operation is planned,
  # without changing the strategies: the console output becomes part of the dry run.
  #
  # One Proxy is installed at boot as +$stdout+ (config/initializers/maintenance_output_capture.rb). It writes to a
  # thread-local buffer while #capture is active on the current thread, and to the wrapped IO otherwise: other threads,
  # RSpec's own output and rake tasks run from a terminal are never affected.
  #
  # == Usage
  #   result, console = Maintenance::OutputCapture.capture { merger.prepare }
  #   Maintenance::OutputCapture.html(console)   # => text without the ANSI color escapes (display only)
  #
  module OutputCapture
    # Thread variable holding the active buffer (a true thread variable, not fiber-local: an Enumerator running
    # a block in a fiber still prints to the same buffer). A literal Symbol on purpose: a proxy installed before a
    # code reload keeps working with the reloaded module.
    THREAD_KEY = :maintenance_output_capture
    ANSI_REGEXP = /\e\[[\d;]*[A-Za-z]/

    #
    # = Maintenance::OutputCapture::Proxy
    #
    # The +$stdout+ stand-in: write, puts, print, putc, printf, <<, flush, sync, sync=, tty?, isatty, fileno; anything
    # else goes to the wrapped IO. #clone / #dup return a real copy of the wrapped IO, so that code saving and
    # restoring +$stdout+ with IO#reopen (e.g. RSpec's to_stdout_from_any_process) restores the terminal.
    #
    class Proxy
      attr_reader :io

      def initialize(io)
        @io = io
      end

      # Marker used instead of is_a? (the class may be reloaded in development).
      def maintenance_capture_proxy? = true

      # The active capture buffer of the current thread, or the wrapped IO.
      def target
        Thread.current.thread_variable_get(THREAD_KEY) || @io
      end

      def capturing? = !Thread.current.thread_variable_get(THREAD_KEY).nil?

      def write(*args) = target.write(*args)
      def puts(*args) = target.puts(*args)
      def print(*args) = target.print(*args)
      def putc(char) = target.putc(char)
      def printf(*args) = target.printf(*args)

      def <<(object)
        target << object
        self
      end

      def flush
        target.flush
        self
      end

      def sync = @io.sync

      def sync=(value)
        @io.sync = value
      end

      def tty? = capturing? ? false : @io.tty?
      alias isatty tty?

      def fileno = @io.fileno
      def to_io = @io.to_io

      def clone(...) = @io.clone(...)
      def dup = @io.dup

      def inspect = "#<#{self.class.name} #{@io.inspect}>"

      def respond_to_missing?(name, include_private = false)
        @io.respond_to?(name, include_private) || super
      end

      def method_missing(name, ...)
        return @io.public_send(name, ...) if @io.respond_to?(name)

        super
      end
    end

    module_function

    # Installs the Proxy as +$stdout+ (once). Returns the proxy.
    def install!
      $stdout = Proxy.new($stdout) unless proxy?($stdout)
      $stdout
    end

    # True when +io+ is a capture proxy.
    def proxy?(io) = io.respond_to?(:maintenance_capture_proxy?)

    # True while a capture is active on the current thread.
    def active? = !Thread.current.thread_variable_get(THREAD_KEY).nil?

    # Runs the block capturing the current thread's +$stdout+ output. Returns [block value, captured String].
    # Nested captures each get their own buffer; the previous buffer (or none) is restored even after an exception.
    # When +$stdout+ is not a proxy (e.g. replaced by a spec), one is installed for the duration of the block.
    def capture
      buffer = StringIO.new
      previous = Thread.current.thread_variable_get(THREAD_KEY)
      swapped = proxy?($stdout) ? nil : $stdout
      $stdout = Proxy.new(swapped) if swapped
      Thread.current.thread_variable_set(THREAD_KEY, buffer)
      [yield, buffer.string]
    ensure
      Thread.current.thread_variable_set(THREAD_KEY, previous)
      $stdout = swapped if swapped
    end

    # +text+ without the ANSI escape sequences (for display only; the stored console keeps them).
    def html(text) = text.to_s.gsub(ANSI_REGEXP, '')
  end
end
