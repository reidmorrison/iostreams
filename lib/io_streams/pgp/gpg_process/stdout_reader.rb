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
      # Responds to the methods of IO that read: `read`, `readpartial`, `gets`, `each_line`, `each` and `eof?`.
      class StdoutReader
        def initialize(stdout, stdin, input)
          @stdout  = stdout
          @stdin   = stdin
          @input   = input
          @buffer  = String.new(encoding: Encoding::BINARY)
          @pending = String.new(encoding: Encoding::BINARY)
          @eof     = false
        end

        # Like IO#read: reads `length` bytes, or less at the end, or everything when `length` is nil.
        # Returns nil at the end when `length` is positive.
        def read(length = nil, outbuf = nil)
          if length
            raise(ArgumentError, "negative length #{length} given") if length.negative?

            fill while @buffer.bytesize < length && !@eof
            if length.positive? && @buffer.empty?
              outbuf&.clear
              return
            end
          else
            fill until @eof
          end
          data = take(length || @buffer.bytesize)
          outbuf ? outbuf.replace(data) : data
        end

        # Like IO#readpartial: returns what is available, up to `maxlen` bytes, waiting only when nothing is.
        # Raises EOFError at the end.
        def readpartial(maxlen, outbuf = nil)
          fill if @buffer.empty?
          raise(EOFError, "end of file reached") if @buffer.empty?

          data = take(maxlen)
          outbuf ? outbuf.replace(data) : data
        end

        # Like IO#gets: returns the next line, ending with the separator, or nil at the end.
        #
        # With the separator "", each line is a paragraph, which ends at a blank line. Like IO#gets, the line endings
        # before a paragraph are skipped, and so are those after the blank line that ends it.
        def gets(separator = $/, limit = nil, chomp: false)
          if separator.is_a?(Integer)
            limit     = separator
            separator = $/
          end
          return read_rest if separator.nil? && limit.nil?

          paragraph = separator == ""
          separator = paragraph ? "\n\n".b : separator&.b
          skip_line_endings if paragraph
          until (size = line_size(separator, limit))
            return read_rest if @eof

            fill
          end
          line = take(size)
          skip_line_endings if paragraph && line.end_with?(separator)
          chomp_line(line, separator, chomp)
        end

        # Like IO#each_line: yields each line.
        def each_line(separator = $/, limit = nil, chomp: false)
          return enum_for(__method__, separator, limit, chomp: chomp) unless block_given?

          while (line = gets(separator, limit, chomp: chomp))
            yield(line)
          end
          self
        end
        alias each each_line

        # Returns [true|false] whether gpg has written everything to its stdout, and it has all been read.
        def eof?
          fill if @buffer.empty?
          @buffer.empty?
        end
        alias eof eof?

        def binmode
          self
        end

        def binmode?
          true
        end

        private

        def take(size)
          @buffer.slice!(0, size)
        end

        # Returns [String] the rest of the data, or nil when there is none.
        def read_rest
          fill until @eof
          return if @buffer.empty?

          take(@buffer.bytesize)
        end

        # Returns [Integer] the size of the next line, which ends with the separator or at the limit,
        # or nil when the buffer does not hold all of it yet.
        def line_size(separator, limit)
          index = separator && @buffer.index(separator)
          size  = index && (index + separator.bytesize)
          limit && @buffer.bytesize >= limit && (size.nil? || size > limit) ? limit : size
        end

        def chomp_line(line, separator, chomp)
          return line unless chomp && separator && line.end_with?(separator)

          line.byteslice(0, line.bytesize - separator.bytesize)
        end

        # Skips the line endings at the start of the data, such as the blank lines between paragraphs.
        def skip_line_endings
          until @buffer.empty? && @eof
            fill if @buffer.empty?
            start = @buffer.index(/[^\n]/n)
            return take(start) if start

            @buffer.clear
          end
        end

        # Reads the next block that gpg has written to its stdout into the buffer, feeding gpg the caller's input
        # while it waits for gpg, or notes that gpg has closed its stdout.
        def fill
          until @eof
            data = @stdout.read_nonblock(BLOCK_SIZE, exception: false)
            case data
            when String
              @buffer << data
              return
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
