# frozen_string_literal: true

require "io/wait"

module IOStreams
  module Pgp
    class GpgProcess
      # Reads what gpg writes to its stdout, feeding gpg the caller's input whenever gpg has nothing ready to be read,
      # all in the caller's thread.
      #
      # So that the caller's input is only read by the caller's thread, and an error reading it is raised to the block
      # as it reads, such as corrupt compressed data, a `Timeout` interrupts a read of an input that stalls, and an
      # input backed by an Enumerator can be read.
      #
      # Reads like an IO, see ChunkReader, one block of what gpg writes at a time.
      class StdoutReader
        include ChunkReader

        def initialize(stdout, stdin, input)
          @stdout  = stdout
          @stdin   = stdin
          @input   = input
          @pending = String.new(encoding: Encoding::BINARY)
          @eof     = false
        end

        def binmode
          self
        end

        def binmode?
          true
        end

        # Returns [true|false] whether gpg's stdout has been closed, once gpg has finished or been stopped.
        def closed?
          @stdout.closed?
        end

        private

        # Returns [String] the next block that gpg has written to its stdout, feeding gpg the caller's input while it
        # waits for gpg, or nil once gpg has closed its stdout.
        def next_chunk
          until @eof
            data = @stdout.read_nonblock(BLOCK_SIZE, exception: false)
            case data
            when String
              return data
            when nil
              @eof = true
            else
              feed
            end
          end
        end

        # Writes the caller's input to gpg's stdin until gpg has written something to its stdout.
        def feed
          return @stdout.wait_readable if @stdin.closed?

          if @pending.empty?
            data = read_input
            # gpg finishes once its input ends.
            return @stdin.close unless data

            @pending = data.b
          end

          _readable, writable = ::IO.select([@stdout], [@stdin])
          write_pending if writable&.any?
        end

        def write_pending
          written  = @stdin.write_nonblock(@pending, exception: false)
          @pending = @pending.byteslice(written..) if written.is_a?(Integer)
        rescue Errno::EPIPE
          # gpg stopped reading its input, which it only does when it fails, which is raised once it has exited.
          @pending.clear
          @stdin.close
        end

        # Returns [String] the next block of the caller's input, or nil at its end.
        def read_input
          data = @input.respond_to?(:readpartial) ? @input.readpartial(BLOCK_SIZE) : @input.read(BLOCK_SIZE)
          data unless data.nil? || data.empty?
        rescue EOFError
          nil
        end
      end
    end
  end
end
