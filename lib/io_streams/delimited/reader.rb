module IOStreams
  module Delimited
    class Reader
      attr_accessor :delimiter

      # Read from a file or stream
      def self.open(file_name_or_io, options={}, &block)
        if IOStreams.reader_stream?(file_name_or_io)
          block.call(new(file_name_or_io, options))
        else
          ::File.open(file_name_or_io, 'rb') do |io|
            block.call(new(io, options))
          end
        end
      end

      # Create a delimited UTF8 stream reader from the supplied input streams
      #
      # The input stream should be binary with no text conversions performed
      # since `strip_non_printable` will be applied to the binary stream before
      # converting to UTF-8
      #
      # Parameters
      #   input_stream
      #     The input stream that implements #read
      #
      #   options
      #     :delimiter[String]
      #       Line / Record delimiter to use to break the stream up into records
      #         Any string to break the stream up by
      #         The records when saved will not include this delimiter
      #       Default: nil
      #         Automatically detect line endings and break up by line
      #         Searches for the first "\r\n" or "\n" and then uses that as the
      #         delimiter for all subsequent records
      #
      #     :buffer_size [Integer]
      #       Maximum size of the buffer into which to read the stream into for
      #       processing.
      #       Must be large enough to hold the entire first line and its delimiter(s)
      #       Default: 65536 ( 64K )
      #
      #     :strip_non_printable [true|false]
      #       Strip all non-printable characters read from the file
      #       Default: false
      #
      #     :encoding
      #       Force encoding to this encoding for all data being read
      #       Default: UTF8_ENCODING
      #       Set to nil to disable encoding
      def initialize(input_stream, options={})
        @input_stream        = input_stream
        options              = options.dup
        @delimiter           = options.delete(:delimiter)
        @buffer_size         = options.delete(:buffer_size) || 65536
        @encoding            = options.has_key?(:encoding) ? options.delete(:encoding) : UTF8_ENCODING
        @strip_non_printable = options.delete(:strip_non_printable)
        @strip_non_printable = @strip_non_printable.nil? && (@encoding == UTF8_ENCODING)
        raise ArgumentError.new("Unknown IOStreams::Delimited::Reader#initialize options: #{options.inspect}") if options.size > 0

        @delimiter.force_encoding(UTF8_ENCODING) if @delimiter && @encoding
        @buffer = ''
      end

      # Returns each line at a time to to the supplied block
      def each(&block)
        partial = nil
        loop do
          if read_chunk == 0
            block.call(partial) if partial
            return
          end

          self.delimiter ||= detect_delimiter
          end_index      ||= (delimiter.size + 1) * -1

          @buffer.each_line(delimiter) do |line|
            if line.end_with?(delimiter)
              # Strip off delimiter
              block.call(line[0..end_index])
              partial = nil
            else
              partial = line
            end
          end
          @buffer = partial.nil? ? '' : partial
        end
      end

      alias_method :each_line, :each

      # Reads length bytes from the I/O stream.
      # Not recommended, but available if someone calls #read on this delimited reader
      def read(length = nil, outbuf = nil)
        if length
          while (@buffer.size < length) && (read_chunk > 0)
          end
          data = @buffer.slice!(0, length)
          outbuf << data if outbuf
          data
        else
          while read_chunk > 0
          end
          @buffer
        end
      end

      ##########################################################################
      private

      NOT_PRINTABLE = Regexp.compile(/[^[:print:]|\r|\n]/)

      # Returns [Integer] the number of bytes read into the internal buffer
      # Returns 0 on EOF
      def read_chunk
        chunk = @input_stream.read(@buffer_size)
        # EOF reached?
        return 0 unless chunk

        # Strip out non-printable characters before converting to UTF-8
        chunk.gsub!(NOT_PRINTABLE, '') if @strip_non_printable

        @buffer << (@encoding ? chunk.force_encoding(@encoding) : chunk)
        chunk.size
      end

      # Auto detect text line delimiter
      def detect_delimiter
        if @buffer =~ /\r\n|\n\r|\n|\r/
          $&
        elsif @buffer.size <= @buffer_size
          # Handle one line files that are smaller than the buffer size
          "\n"
        end
      end

    end
  end
end
