# frozen_string_literal: true

require 'English'
require 'open3'

module DbRestore
  #
  # = DbRestore::Commands
  #
  # The external processes of a restore, each called with an argv Array (never through a shell) and the child
  # environment (the DB password travels only as MYSQL_PWD there; see DbRestore::Target). Error output is
  # returned truncated and never contains a credential (the clients don't echo it).
  #
  # Specs replace this module with a fake (DbRestore::Loader / DbRestore::Snapshot take +commands:+) or run it with
  # harmless commands (bzip2 / cat): no spec ever starts a MySQL client.
  #
  module Commands # rubocop:disable Metrics/ModuleLength
    CHUNK = 256.kilobytes
    # Bytes at the start of the uncompressed stream searched for the sandbox line (the 7th line of a db:dump file).
    HEAD_BYTES = 4.kilobytes
    SANDBOX_LINE = %r{^/\*M!999999\\- enable the sandbox mode \*/[^\n]*\n}
    STDERR_LIMIT = 4.kilobytes

    module_function

    # Runs +argv+ with +env+; raises DbRestore::CommandFailed (with the error output) on a non-zero exit.
    def capture!(env, argv)
      out, err, status = Open3.capture3(env, *argv)
      raise CommandFailed, failure_text(argv, err, status) unless status.success?

      out
    rescue SystemCallError => e
      raise CommandFailed, "#{argv.first}: #{e.class}: #{e.message}"
    end

    # Output of +argv+ (stdout, stripped), or nil when it fails.
    def output(argv)
      out, _err, status = Open3.capture3(*argv)
      status.success? ? out.to_s.strip : nil
    rescue SystemCallError
      nil
    end

    # Streams the compressed +input_path+ through +decompress_argv+ (e.g. bunzip2 -c) into +client_argv+ (the MySQL
    # client reading SQL on stdin), dropping the sandbox line when +filter_sandbox+; yields the compressed bytes fed
    # so far after each chunk (progress). Raises DbRestore::CommandFailed when a process fails. Returns the client's
    # stdout (truncated).
    # rubocop:disable-next Metrics/AbcSize
    def load_stream(env:, decompress_argv:, client_argv:, input_path:, filter_sandbox: false, &progress)
      Open3.popen3(*decompress_argv) do |dz_in, dz_out, dz_err, dz_wait|
        Open3.popen3(env, *client_argv) do |cl_in, cl_out, cl_err, cl_wait|
          [dz_in, dz_out, cl_in].each(&:binmode)
          readers = { dz_err: reader(dz_err), cl_err: reader(cl_err), cl_out: reader(cl_out) }
          feeder = feed(input_path, dz_in, &progress)
          copy(dz_out, cl_in, filter_sandbox:)
          feeder.join
          dz_status = dz_wait.value
          cl_status = cl_wait.value
          texts = readers.transform_values(&:value)
          raise CommandFailed, failure_text(client_argv, texts[:cl_err], cl_status) unless cl_status.success?
          raise CommandFailed, "#{input_path}: #{feeder.value.class}: #{feeder.value.message}" if feeder.value.is_a?(Exception)
          raise CommandFailed, failure_text(decompress_argv, texts[:dz_err], dz_status) unless dz_status.success?

          texts[:cl_out]
        end
      end
    end

    # Writes +header+, the stdout of +dump_argv+ (each line passed through +line_filter+, when given) and +footer+,
    # compressed with bzip2, to +out_path+. Raises DbRestore::CommandFailed when a process fails.
    # rubocop:disable-next Metrics/ParameterLists
    def dump_to(env:, dump_argv:, out_path:, header: '', footer: '', line_filter: nil)
      File.open(out_path, 'wb') do |file|
        IO.popen(%w[bzip2 -c], 'wb', out: file) do |bz|
          bz.write(header)
          Open3.popen3(env, *dump_argv) do |dump_in, dump_out, dump_err, dump_wait|
            dump_in.close
            err = reader(dump_err)
            dump_out.binmode
            dump_out.each_line { |line| bz.write(line_filter ? line_filter.call(line) : line) }
            status = dump_wait.value
            raise CommandFailed, failure_text(dump_argv, err.value, status) unless status.success?
          end
          bz.write(footer)
        end
        raise CommandFailed, "bzip2 exited with status #{$CHILD_STATUS&.exitstatus}" unless $CHILD_STATUS&.success?
      end
      out_path
    rescue SystemCallError, IOError => e
      raise CommandFailed, "#{dump_argv.first}: #{e.class}: #{e.message}"
    end

    # Free bytes on the filesystem of +dir+ ('df -Pk'), or nil when unknown.
    def free_bytes(dir)
      out = output(['df', '-Pk', dir.to_s])
      kilobytes = out.to_s.lines.last.to_s.split[3]
      kilobytes&.match?(/\A\d+\z/) ? kilobytes.to_i * 1024 : nil
    end

    # (helpers)
    def reader(io)
      Thread.new do
        Thread.current.report_on_exception = false
        io.binmode
        io.read.to_s.byteslice(0, STDERR_LIMIT).to_s.force_encoding(Encoding::UTF_8).scrub('')
      end
    end

    # Thread copying the compressed file into the decompressor (yields the bytes fed); its value is an Exception
    # when the copy failed for another reason than a closed pipe.
    def feed(input_path, dz_in, &progress)
      Thread.new do
        Thread.current.report_on_exception = false
        fed = 0
        File.open(input_path, 'rb') do |file|
          while (chunk = file.read(CHUNK))
            dz_in.write(chunk)
            fed += chunk.bytesize
            progress&.call(fed)
          end
        end
        nil
      rescue Errno::EPIPE, IOError
        nil
      rescue StandardError => e
        e
      ensure
        dz_in.close unless dz_in.closed?
      end
    end

    # Copies the decompressed SQL into the client (dropping the sandbox line at the start when asked).
    def copy(dz_out, cl_in, filter_sandbox:)
      dz_out.binmode
      head = dz_out.read(HEAD_BYTES).to_s
      head = head.sub(SANDBOX_LINE, '') if filter_sandbox
      cl_in.write(head)
      IO.copy_stream(dz_out, cl_in)
    rescue Errno::EPIPE, IOError
      nil # (the client stopped: its exit status and error output tell why)
    ensure
      cl_in.close unless cl_in.closed?
      dz_out.close unless dz_out.closed?
    end

    def failure_text(argv, err, status)
      code = status.respond_to?(:exitstatus) ? status.exitstatus : status
      text = err.to_s.strip.presence || 'no error output'
      "#{argv.first} exited with status #{code}: #{text}".truncate(STDERR_LIMIT)
    end
  end
end
