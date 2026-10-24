# frozen_string_literal: true

module IOStreams
  module Line
    class Reader < IOStreams::Reader
      include Enumerable

      attr_reader :delimiter, :buffer_size, :line_number

      # Prevent denial of service when a delimiter is not found before this number * `buffer_size` bytes are read.
      MAX_BLOCKS_MULTIPLIER = 100

      # The size of the blocks read from the input stream, when no `buffer_size` is supplied.
      DEFAULT_BUFFER_SIZE = 65_536

      # Prevent denial of service when a quoted value is not closed before this number * `buffer_size` bytes, see
      # .max_embedded_bytes.
      MAX_EMBEDDED_BLOCKS = 10

      LINEFEED_REGEXP = /\r\n|\n|\r/

      # Returns [Array<Symbol>] the options that the reader accepts, see #initialize, which are the options of each call
      # that reads lines, see `IOStreams::Stream#reader`, which raises for any other.
      def self.option_names
        %i[delimiter buffer_size embedded_within]
      end

      # Returns [Integer] the most bytes that a line whose quoted value holds line endings can reach before #readline
      # raises `IOStreams::Errors::MalformedDataError`, rather than keep reading the lines after it into memory:
      # MAX_EMBEDDED_BLOCKS blocks of the supplied size, 640KB by default.
      def self.max_embedded_bytes(buffer_size = DEFAULT_BUFFER_SIZE)
        buffer_size * MAX_EMBEDDED_BLOCKS
      end

      # Read a line at a time from a stream
      def self.stream(input_stream, **)
        yield new(input_stream, **)
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
      #       Searches for the first "\r\n", "\n" or "\r", such as of a file written on an old Mac, and then uses
      #       that as the delimiter for all subsequent records. When it is "\r\n", a "\n" also ends a line, and the
      #       "\r" before it is removed, so that a file whose lines end in both ways, such as a Windows file to which
      #       a program on Linux added lines, is read line by line.
      #
      #   buffer_size: [Integer]
      #     Size of blocks to read from the input stream at a time.
      #     Default: nil, which reads DEFAULT_BUFFER_SIZE bytes, 64KB, at a time.
      #
      #   embedded_within: [String]
      #     Supports CSV files where a line may contain an embedded newline.
      #     For CSV files set `embedded_within: '"'`
      #
      # Note:
      # * When reached via `IOStreams::Stream`, `embedded_within` defaults to the quote character of the
      #   tabular format (e.g. `"` for CSV). See `IOStreams::Tabular#quote_character`.
      def initialize(input_stream, delimiter: nil, buffer_size: nil, embedded_within: nil)
        super(input_stream)
        unless buffer_size.nil? || (buffer_size.is_a?(Integer) && buffer_size.positive?)
          raise(ArgumentError, "Invalid buffer_size #{buffer_size.inspect}: supply the number of bytes to read at a time")
        end

        @embedded_within = embedded_within
        @buffer_size     = buffer_size || DEFAULT_BUFFER_SIZE

        # More efficient read buffering only supported when the input stream `#read` method supports it.
        @use_read_cache_buffer = !@input_stream.method(:read).arity.between?(0, 1)

        @line_number       = 0
        @start_line_number = nil
        @eof               = false
        @read_cache_buffer = nil
        @buffer            = nil
        @encoding          = nil
        @delimiter         = delimiter

        read_block
        # Auto-detect windows, linux or old Mac line endings if not supplied: \r\n, \n or \r
        @delimiter ||= auto_detect_line_endings
        # Lines whose detected ending is "\r\n" also end at a "\n" without a "\r", see #initialize.
        @crlf = delimiter.nil? && @delimiter == "\r\n"

        return unless @buffer

        # Change the delimiters encoding to match that of the input stream
        @delimiter = @delimiter.encode(@encoding)
        @newline   = "\n".encode(@encoding)
        # The delimiter as it is searched for within the buffer, see #buffer_encoding.
        @separator = (@crlf ? @newline : @delimiter).dup.force_encoding(@buffer.encoding)
        @return    = "\r".encode(@encoding).force_encoding(@buffer.encoding) if @crlf
        # The ending of the last line read, which a line that continues a quoted value is joined with, see #readline.
        @ending    = @delimiter
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

      # Iterates over every line, as #each does, passing each one to the supplied block with the number of the line that
      # it starts on, counting from 1, as a text editor numbers it. It is before #line_number, the line that it ends on,
      # when the line holds the line endings within a quoted value, see `embedded_within`.
      #
      # Returns [Integer] the number of lines read from the file/stream.
      def each_with_line_number
        line_count = 0
        until eof?
          line = readline
          unless line.nil?
            yield(line, @start_line_number)
            line_count += 1
          end
        end
        line_count
      end

      # Writes each line to the writer, see `IOStreams::Line::Writer`, as a copy does, see `IOStreams::Stream#copy_from`,
      # including a blank line, which is a line of its own.
      #
      # Returns [Integer] the number of lines read, see #each.
      def copy_to(writer)
        each { |line| writer << line }
      end

      # Reads each line per the `delimeter`.
      # Accounts for lines that contain the `delimiter` when the `delimeter` is within the `embedded_within` delimiter.
      # For Example, CSV files can contain newlines embedded within double quotes.
      def readline
        line               = _readline
        @start_line_number = @line_number if line
        if line && @embedded_within
          # Count the delimiters incrementally, since recounting the whole line each time is quadratic.
          # For the same reason limit the size of the line in bytes, since `#length` counts the characters
          # in a multi-byte string such as UTF-8 each time it is called.
          embedded_count = line.count(@embedded_within)
          while embedded_count.odd?
            if eof? || line.bytesize > self.class.max_embedded_bytes(@buffer_size)
              raise(Errors::MalformedDataError.new(
                      "Unbalanced delimited field, delimiter: #{@embedded_within}",
                      @start_line_number
                    ))
            end
            line << @ending
            embedded_count += @ending.count(@embedded_within)
            next_line = _readline
            if next_line.nil?
              raise(Errors::MalformedDataError.new(
                      "Unbalanced delimited field, delimiter: #{@embedded_within}",
                      @start_line_number
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

      # Returns [String] the class and the delimiter of the lines, which the reader detects unless it was supplied,
      # rather than every instance variable, such as the stream that it reads and the block of data that it holds, so
      # that irb, which displays what a reader block returns, shows what the documentation describes.
      def inspect
        "#<#{self.class.name} delimiter=#{delimiter.inspect}>"
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

        data = remove_return(data) if @crlf && data
        data&.force_encoding(@encoding)
      end

      # Returns [String] the line without the "\r" that ends it, when the line ends with "\r\n", and notes how it
      # ended, see #readline. A line that ends with "\n" alone keeps every "\r" within it.
      def remove_return(data)
        unless data.end_with?(@return)
          @ending = @newline
          return data
        end

        @ending = @delimiter
        data.byteslice(0, data.bytesize - @return.bytesize)
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

        loop do
          # Could be "\r\n" broken in half by the block size
          read_block if @buffer.end_with?(buffer_text("\r"))

          ending = first_line_ending
          return ending if ending
          # One line files with no delimiter
          return "\n" unless read_block
        end
      end

      # Returns [String] the first line ending in the buffer, "\r\n", "\n" or "\r", or nil when it has none.
      #
      # Each ending is searched for in the encoding of the data, rather than with a Regexp, which cannot search text in
      # an encoding that is not ASCII compatible, such as the UTF-16 of a Windows "Unicode Text" export.
      def first_line_ending
        return_at  = @buffer.index(buffer_text("\r"))
        newline_at = @buffer.index(buffer_text("\n"))
        return if return_at.nil? && newline_at.nil?
        return "\n" if return_at.nil? || (newline_at && newline_at < return_at)

        newline_at == return_at + 1 ? "\r\n" : "\r"
      end

      # Returns [String] the text in the encoding of the buffer, see #buffer_encoding.
      def buffer_text(text)
        text.encode(@encoding).force_encoding(@buffer.encoding)
      end
    end
  end
end
