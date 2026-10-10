module IOStreams
  module Line
    class Reader < IOStreams::Reader
      attr_reader :delimiter, :buffer_size, :line_number

      # Prevent denial of service when a delimiter is not found before this number * `buffer_size` bytes are read.
      MAX_BLOCKS_MULTIPLIER = 100

      LINEFEED_REGEXP = /\r\n|\n|\r/

      # Read a line at a time from a stream
      def self.stream(input_stream, **args)
        # Pass-through if already a line reader
        return yield(input_stream) if input_stream.is_a?(self)

        yield new(input_stream, **args)
      end

      # Create a delimited stream reader from the supplied input stream.
      #
      # Lines returned will be in the encoding of the input stream.
      # To change the encoding of returned lines, use IOStreams::Encode::Reader.
      #
      # Parameters
      #   input_stream
      #     The input stream that implements #read
      #
      #   delimiter: [String]
      #     Line / Record delimiter to use to break the stream up into records
      #       Any string to break the stream up by.
      #       This delimiter is removed from each line when `#each` or `#readline` is called.
      #     Default: nil
      #       Automatically detect line endings and break up by line
      #       Searches for the first "\r\n" or "\n" and then uses that as the
      #       delimiter for all subsequent records.
      #
      #   buffer_size: [Integer]
      #     Size of blocks to read from the input stream at a time.
      #     Default: 65536 ( 64K )
      #
      #   embedded_within: [String]
      #     Supports CSV files where a line may contain an embedded newline.
      #     For CSV files set `embedded_within: '"'`
      #
      # Note:
      # * When reached via `IOStreams::Stream`, `embedded_within` defaults to the quote character of the
      #   tabular format (e.g. `"` for CSV). See `IOStreams::Tabular#quote_character`.
      def initialize(input_stream, delimiter: nil, buffer_size: 65_536, embedded_within: nil)
        super(input_stream)

        @embedded_within = embedded_within
        @buffer_size     = buffer_size

        # More efficient read buffering only supported when the input stream `#read` method supports it.
        @use_read_cache_buffer = !@input_stream.method(:read).arity.between?(0, 1)

        @line_number       = 0
        @eof               = false
        @read_cache_buffer = nil
        @buffer            = nil
        @encoding          = nil
        @delimiter         = delimiter

        read_block
        # Auto-detect windows/linux line endings if not supplied. \n or \r\n
        @delimiter ||= auto_detect_line_endings

        return unless @buffer

        # Change the delimiters encoding to match that of the input stream
        @delimiter = @delimiter.encode(@encoding)
        # The delimiter as it is searched for within the buffer, see #buffer_encoding.
        @separator = @delimiter.dup.force_encoding(@buffer.encoding)
      end

      # Iterate over every line in the file/stream passing each line to supplied block in turn.
      # Returns [Integer] the number of lines read from the file/stream.
      # Note:
      # * The line delimiter is _not_ returned.
      def each
        line_count = 0
        until eof?
          line = readline
          unless line.nil?
            yield(line)
            line_count += 1
          end
        end
        line_count
      end

      # Reads each line per the `delimeter`.
      # Accounts for lines that contain the `delimiter` when the `delimeter` is within the `embedded_within` delimiter.
      # For Example, CSV files can contain newlines embedded within double quotes.
      def readline
        line = _readline
        if line && @embedded_within
          initial_line_number = @line_number
          # Count the delimiters incrementally, since recounting the whole line each time is quadratic.
          # For the same reason limit the size of the line in bytes, since `#length` counts the characters
          # in a multi-byte string such as UTF-8 each time it is called.
          embedded_count      = line.count(@embedded_within)
          while embedded_count.odd?
            if eof? || line.bytesize > @buffer_size * 10
              raise(Errors::MalformedDataError.new(
                      "Unbalanced delimited field, delimiter: #{@embedded_within}",
                      initial_line_number
                    ))
            end
            line << @delimiter
            embedded_count += @delimiter.count(@embedded_within)
            next_line = _readline
            if next_line.nil?
              raise(Errors::MalformedDataError.new(
                      "Unbalanced delimited field, delimiter: #{@embedded_within}",
                      initial_line_number
                    ))
            end
            line << next_line
            embedded_count += next_line.count(@embedded_within)
          end
        end
        line
      end

      # Returns whether the end of file has been reached for this stream
      def eof?
        @eof && (@buffer.nil? || @buffer.empty?)
      end

      private

      def _readline
        return if eof?

        # Keep reading until it finds the delimiter
        while (index = @buffer.byteindex(@separator)).nil? && read_block
        end

        # Delimiter found?
        if index
          data         = @buffer.byteslice(0, index)
          @buffer      = @buffer.byteslice(index + @separator.bytesize, @buffer.bytesize)
          @line_number += 1
        elsif @eof && @buffer.empty?
          data    = nil
          @buffer = nil
        else
          # Last line without delimiter
          data         = @buffer
          @buffer      = nil
          @line_number += 1
        end

        data&.force_encoding(@encoding)
      end

      # Returns whether more data is available to read
      # Returns false on EOF
      def read_block
        return false if @eof

        block = read_input

        # EOF reached?
        if block.nil?
          @eof = true
          return false
        end

        if @buffer
          @buffer << (block.encoding == @buffer.encoding ? block : block.b)
        else
          # Take on the encoding from the first block that was read.
          @encoding          = block.encoding
          @buffer            = block.dup.force_encoding(buffer_encoding)
          @read_cache_buffer = "".encode(block.encoding) if @use_read_cache_buffer
        end

        if @buffer.bytesize > MAX_BLOCKS_MULTIPLIER * @buffer_size
          raise(
            Errors::DelimiterNotFound,
            "Delimiter: #{@delimiter.inspect} not found after reading #{@buffer.bytesize} bytes."
          )
        end

        true
      end

      def read_input
        return @input_stream.read(@buffer_size) unless @read_cache_buffer

        begin
          @input_stream.read(@buffer_size, @read_cache_buffer)
        rescue ArgumentError
          # Handle arity of -1 when just 0..1
          @read_cache_buffer     = nil
          @use_read_cache_buffer = false
          @input_stream.read(@buffer_size)
        end
      rescue Errors::InvalidEncoding => e
        e.line_number = next_line_number
        raise
      end

      # Returns [Integer] the number of the line that the next data read is on: the line after those already read,
      # and after those still in the buffer, which the encode stream returns before the invalid data that follows.
      def next_line_number
        return @line_number + 1 unless @buffer

        @line_number + 1 + @buffer.scan(@separator || LINEFEED_REGEXP).size
      end

      # Returns [Encoding] the encoding of the buffer that holds the data read, in which the delimiter is searched for.
      #
      # UTF-8 is held as binary, since a UTF-8 delimiter can only match the bytes of whole characters.
      # Searching it as UTF-8 is far slower: each line sliced off the front leaves a new string, which Ruby
      # validates again from its start before the next search, so every line rescans the rest of the buffer.
      # Other encodings are searched by character, since in some, such as Shift_JIS, the second byte of a
      # character can match a delimiter such as `|`.
      def buffer_encoding
        @encoding == Encoding::UTF_8 ? Encoding::BINARY : @encoding
      end

      # Auto-detect windows/linux line endings: \n, \r or \r\n
      def auto_detect_line_endings
        return "\n" if @buffer.nil? && !read_block

        # Could be "\r\n" broken in half by the block size
        read_block if @buffer[-1] == "\r"

        # Delimiter takes on the encoding from @buffer
        delimiter = @buffer.slice(LINEFEED_REGEXP)
        return delimiter if delimiter

        while read_block
          # Could be "\r\n" broken in half by the block size
          read_block if @buffer[-1] == "\r"

          # Delimiter takes on the encoding from @buffer
          delimiter = @buffer.slice(LINEFEED_REGEXP)
          return delimiter if delimiter
        end

        # One line files with no delimiter
        "\n"
      end
    end
  end
end
