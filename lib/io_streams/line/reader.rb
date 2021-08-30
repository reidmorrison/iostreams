module IOStreams
  module Line
    class Reader < IOStreams::Reader
      attr_reader :delimiter, :buffer_size, :line_number

      # Prevent denial of service when a delimiter is not found before this number * `buffer_size` characters are read.
      MAX_BLOCKS_MULTIPLIER = 100

      LINEFEED_REGEXP = Regexp.compile(/\r\n|\n|\r/).freeze

      # Read a line at a time from a stream
      def self.stream(input_stream, **args)
        # Pass-through if already a line reader
        return yield(input_stream) if input_stream.is_a?(self.class)

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
      # * When using a line reader and the file_name ends with ".csv" then embedded_within is automatically set to `"`
      def initialize(input_stream, delimiter: nil, buffer_size: 65_536, embedded_within: nil, original_file_name: nil)
        super(input_stream)

        @embedded_within = embedded_within
        @buffer_size     = buffer_size

        # More efficient read buffering only supported when the input stream `#read` method supports it.
        @use_read_cache_buffer = !@input_stream.method(:read).arity.between?(0, 1)

        @line_number       = 0
        @eof               = false
        @read_cache_buffer = nil
        @buffer            = nil
        @delimiter         = delimiter

        read_block
        # Auto-detect windows/linux line endings if not supplied. \n or \r\n
        @delimiter ||= auto_detect_line_endings

        return unless @buffer

        # Change the delimiters encoding to match that of the input stream
        @delimiter      = @delimiter.encode(@buffer.encoding)
        @delimiter_size = @delimiter.size
      end

      # Iterate over every line in the file/stream passing each line to supplied block in turn.
      # Returns [Integer] the number of lines read from the file/stream.
      # Note:
      # * The line delimiter is _not_ returned.
      def each
        return to_enum(__method__) unless block_given?

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
          while line.count(@embedded_within).odd?
            if eof? || line.length > @buffer_size * 10
              raise(Errors::MalformedDataError.new(
                      "Unbalanced delimited field, delimiter: #{@embedded_within}",
                      initial_line_number
                    ))
            end
            line << @delimiter
            next_line = _readline
            if next_line.nil?
              raise(Errors::MalformedDataError.new(
                      "Unbalanced delimited field, delimiter: #{@embedded_within}",
                      initial_line_number
                    ))
            end
            line << next_line
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
        while (index = @buffer.index(@delimiter)).nil? && read_block
        end

        # Delimiter found?
        if index
          data         = @buffer.slice(0, index)
          @buffer      = @buffer.slice(index + @delimiter_size, @buffer.size)
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

        data
      end

      # Returns whether more data is available to read
      # Returns false on EOF
      def read_block
        return false if @eof

        block =
          if @read_cache_buffer
            begin
              @input_stream.read(@buffer_size, @read_cache_buffer)
            rescue ArgumentError
              # Handle arity of -1 when just 0..1
              @read_cache_buffer     = nil
              @use_read_cache_buffer = false
              @input_stream.read(@buffer_size)
            end
          else
            @input_stream.read(@buffer_size)
          end

        # EOF reached?
        if block.nil?
          @eof = true
          return false
        end

        if @buffer
          @buffer << block
        else
          # Take on the encoding from the input stream
          @buffer            = block.dup
          # Take on the encoding from the first block that was read.
          @read_cache_buffer = "".encode(block.encoding) if @use_read_cache_buffer
        end

        if @buffer.size > MAX_BLOCKS_MULTIPLIER * @buffer_size
          raise(
            Errors::DelimiterNotFound,
            "Delimiter: #{@delimiter.inspect} not found after reading #{@buffer.size} bytes."
          )
        end

        true
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
