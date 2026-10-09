require "stringio"

module IOStreams
  module Pgp
    class GpgProcess
      # Writes to gpg's stdin, passing what gpg writes to its stdout on to the caller's output whenever gpg is not
      # ready for more, all in the caller's thread.
      #
      # So that the caller's output is only written by the caller's thread, and an error writing it, such as a full
      # disk or a broken pipe, is raised to the block as it writes, and a `Timeout` interrupts a write to an output
      # that stalls.
      #
      # Responds to the methods of IO that write: `write`, `<<`, `print`, `puts`, `printf` and `flush`.
      class StdinWriter
        def initialize(stdin, stdout, output, process)
          @stdin   = stdin
          @stdout  = stdout
          @output  = output
          @process = process
          @eof     = false
        end

        # Like IO#write: writes each object as a string, and returns the number of bytes written.
        def write(*objects)
          objects.sum { |object| write_data(object.to_s) }
        end

        def <<(object)
          write(object)
          self
        end

        def print(*)
          write(*)
          nil
        end

        def puts(*)
          lines = StringIO.new(+"")
          lines.puts(*)
          write(lines.string)
          nil
        end

        def printf(format, *)
          write(Kernel.format(format, *))
          nil
        end

        # gpg's stdin is not buffered, so there is nothing to flush.
        def flush
          self
        end

        def binmode
          self
        end

        def binmode?
          true
        end

        # Ends gpg's input, and passes the rest of what gpg writes to its stdout on to the caller's output.
        def finish
          @stdin.close
          ::IO.copy_stream(@stdout, @output) unless @eof
        end

        private

        def write_data(data)
          remaining = data
          until remaining.empty?
            written = write_stdin(remaining)
            if written.is_a?(Integer)
              remaining = remaining.byteslice(written..)
            else
              wait_writable
            end
          end
          data.bytesize
        end

        # Writes what gpg's stdin takes without waiting. Only a broken pipe from gpg's stdin is gpg's failure, not one
        # from the caller's output, or from the block.
        def write_stdin(data)
          @stdin.write_nonblock(data, exception: false)
        rescue Errno::EPIPE => e
          @process.stopped_reading(e)
        end

        # Waits until gpg reads more of its stdin, passing what gpg writes to its stdout on to the caller's output
        # in the meantime, since gpg stops reading once its stdout is full.
        def wait_writable
          readable, = ::IO.select(@eof ? [] : [@stdout], [@stdin])
          deliver_available if readable&.any?
        end

        # Writes what gpg has written to its stdout so far to the caller's output, without waiting for more.
        def deliver_available
          loop do
            data = @stdout.read_nonblock(BLOCK_SIZE, exception: false)
            @eof = true if data.nil?
            break unless data.is_a?(String)

            @output.write(data)
          end
        end
      end
    end
  end
end
