module IOStreams
  module Pgp
    # One run of gpg, which moves the data between gpg and the caller's stream in the caller's thread.
    #
    # The block reads what gpg decrypts from `#stdout`, or writes what gpg encrypts to `#stdin`. Whenever gpg is
    # waiting, these feed it the caller's input, or pass what it wrote on to the caller's output, in the caller's
    # thread, so that the caller's stream is only ever used by the caller's thread, such as a stream backed by an
    # Enumerator, and so that `Timeout` and any error reading or writing the stream reach the caller unchanged.
    #
    # gpg is stopped by closing its pipes rather than by a signal, so that it exits cleanly, removing its lock
    # files, and so that a gpg started by a wrapper executable, such as `sudo -u pgp gpg`, also stops.
    #
    # Used internally by the PGP reader and writer.
    class GpgProcess
      autoload :StdinWriter, "io_streams/pgp/gpg_process/stdin_writer"
      autoload :StdoutReader, "io_streams/pgp/gpg_process/stdout_reader"

      # Bytes moved at a time between gpg and the caller's stream.
      BLOCK_SIZE = 65_536

      # Runs gpg, yielding this process, and returns the result of the block.
      #
      # Parameters:
      #   command: [Array<String>]
      #     The gpg command line.
      #   failure: [String]
      #     The start of the message raised when gpg fails, such as "GPG Failed to decrypt".
      #   input: [IO]
      #     The caller's stream that gpg reads, when decrypting.
      #   output: [IO]
      #     The caller's stream that gpg writes to, when encrypting.
      #   passphrases: [Hash<Integer, String>]
      #     The passphrase that gpg reads on each of these file descriptors.
      #   captures: [Array<Integer>]
      #     File descriptors whose output from gpg is kept, such as its status, see `#captured`.
      #
      # When the block raises, gpg is stopped before it completes its output from partial data, and the exception
      # is raised once gpg has exited. The caller's stream is never closed, since it belongs to the caller.
      def self.run(command, failure:, input: nil, output: nil, passphrases: {}, captures: [])
        gpg = new(command, failure: failure, input: input, output: output, passphrases: passphrases, captures: captures)
        begin
          yield(gpg)
        ensure
          gpg.stop
        end
      end

      # Returns [File] the caller's input when gpg can read it through its file descriptor: a regular file that is
      # open for reading, including the file of a Tempfile. Ruby's read buffer is discarded first, so that gpg starts
      # where the caller would read next.
      def self.readable_file(io)
        file = local_file(io)
        return unless file&.stat&.file?

        file.seek(file.pos)
        # Raises IOError when the file was not opened for reading, without reading from it.
        file.read(0)
        file
      rescue IOError, SystemCallError
        nil
      end

      # Returns [String] the absolute name of the file that the caller's stream reads or writes, for messages,
      # or nil for any other stream.
      def self.file_name(io)
        file = local_file(io)
        ::File.absolute_path(file.path) if file&.path
      rescue IOError, SystemCallError
        nil
      end

      # Returns [File] the open file of the stream, including the file of a Tempfile, or nil for any other stream.
      def self.local_file(io)
        file = defined?(::Delegator) && io.is_a?(::Delegator) ? io.__getobj__ : io
        file if file.is_a?(::File) && !file.closed?
      end
      private_class_method :local_file

      def initialize(command, failure:, input:, output:, passphrases:, captures:)
        @failure  = failure
        @output   = output
        @name     = self.class.file_name(input || output)
        file      = self.class.readable_file(input) if input
        @input    = input unless file
        @captured = {}
        @drains   = {}
        child     = child_ios(file, passphrases, captures)

        begin
          @gpg = ::Process.detach(::Process.spawn(*command, child))
        ensure
          # So that each pipe ends once gpg exits. The caller's file belongs to the caller.
          child.each_value { |io| io.close unless io.equal?(file) }
        end
        drain([@stderr, *@captured.values])
        @stdin&.binmode
        @stdout.binmode
      rescue StandardError
        close_pipes
        raise
      end

      # Returns the stream that the block reads what gpg writes to its stdout from: gpg's stdout itself when gpg reads
      # the caller's file, otherwise a `StdoutReader`, which also feeds the caller's input to gpg.
      def reader
        return @stdout unless @stdin

        @reader ||= StdoutReader.new(@stdout, @stdin, @input)
      end

      # Returns [StdinWriter] the stream that the block writes what gpg reads from its stdin to, which also passes
      # what gpg writes to its stdout on to the caller's output.
      def writer
        @writer ||= StdinWriter.new(@stdin, @stdout, @output, self)
      end

      # Ends gpg's input, passes the rest of its output on to the caller's output, and waits for gpg to exit.
      # Raises Pgp::Failure when gpg fails.
      def finish
        if @writer
          @writer.finish
        else
          @stdin&.close
        end
        wait
        raise(Pgp::Failure, "#{@failure} #{subject}: #{errors}") unless @status.success?
      end

      # Stops gpg unless it has exited, and closes its pipes.
      def stop
        return close_pipes if @status

        # Once its stdout is closed, gpg stops at its next write, and once its stdin is closed it no longer waits for
        # more input, so that it never completes its output from partial data.
        @stdout.close
        @stdin&.close
        wait
      ensure
        close_pipes
      end

      # Called once gpg has stopped reading what the block writes to its stdin, which it only does when it fails.
      # Raises Pgp::Failure once gpg has exited, or the supplied error when gpg succeeded.
      def stopped_reading(error)
        @stdout.close
        @stdin.close
        wait
        raise(Pgp::Failure, "#{@failure} #{subject}: #{errors}") unless @status.success?

        raise(error)
      end

      # Returns [String] what gpg wrote to the supplied file descriptor, once gpg has finished.
      def captured(descriptor)
        @texts.fetch(@captured.fetch(descriptor))
      end

      # Returns [String] what gpg is processing, for an error message: the named file, or the stream.
      def subject
        @name ? "file: #{@name}" : "stream"
      end

      # Returns [String] a message about the PGP data that gpg is processing, naming the file when there is one,
      # such as "PGP file was not signed by sender@example.org: /data/a.csv.pgp".
      def describe(text)
        @name ? "PGP file #{text}: #{@name}" : "PGP stream #{text}"
      end

      private

      # Waits for gpg to exit, and for its other output to be read, so that the pipes are only closed once no thread
      # is reading them.
      def wait
        @status = @gpg.value
        @texts  = @drains.transform_values(&:value)
      end

      def errors
        @texts.fetch(@stderr).to_s.chomp
      end

      # Returns [Hash<Integer|Symbol, IO>] the IOs that only gpg uses, by the file descriptor that gpg uses them on:
      # the caller's file, or its end of a pipe for its stdin, and its ends of the other pipes.
      def child_ios(file, passphrases, captures)
        child = {}
        if file
          child[:in] = file
        else
          child[:in], @stdin = ::IO.pipe
        end
        @stdout, child[:out] = ::IO.pipe
        @stderr, child[:err] = ::IO.pipe
        passphrases.each_pair { |descriptor, passphrase| child[descriptor] = passphrase_pipe(passphrase) }
        captures.each { |descriptor| @captured[descriptor], child[descriptor] = ::IO.pipe }
        child
      end

      # Reads what gpg writes to each of these pipes while it runs, so that gpg never waits for it to be read.
      def drain(pipes)
        pipes.each do |io|
          thread                     = Thread.new { io.read }
          thread.report_on_exception = false
          @drains[io]                = thread
        end
      end

      # Returns [IO] the read end of a pipe that holds the passphrase, so that it is not visible in the process list.
      # It is written before gpg starts, so that gpg never waits for it.
      def passphrase_pipe(passphrase)
        reader, writer = ::IO.pipe
        writer.puts(passphrase.to_s)
        writer.close
        reader
      end

      def close_pipes
        [@stdin, @stdout, @stderr, *@captured.values].each { |io| io&.close }
      end
    end
  end
end
