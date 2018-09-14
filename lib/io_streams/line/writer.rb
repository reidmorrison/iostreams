module IOStreams
  module Line
    class Writer
      attr_reader :delimiter, :encoding, :strip_non_printable

      # Write a line at a time to a file or stream
      def self.open(file_name_or_io, **args)
        if file_name_or_io.is_a?(String)
          IOStreams::File::Writer.open(file_name_or_io) { |io| yield new(io, **args) }
        else
          yield new(file_name_or_io, **args)
        end
      end

      NOT_PRINTABLE = Regexp.compile(/[^[:print:]]/)

      # A delimited stream writer that will write to the supplied output stream
      #
      # The output stream should be binary with no text conversions performed
      # since `strip_non_printable` will be applied to the binary stream before
      # converting to UTF-8
      #
      # Parameters
      #   output_stream
      #     The output stream that implements #write
      #
      #   delimiter: [String]
      #     Add the specified delimiter after every record when writing it
      #     to the output stream
      #     Default: OS Specific. Linux: "\n"
      #
      #   encoding:
      #     Encode data before writing to the output stream.
      #     Default: UTF8_ENCODING
      #     Set to nil to disable encoding
      #
      #   strip_non_printable: [true|false]
      #     Strip all non-printable characters before writing to the file / stream.
      #     Default: false
      #
      # TODO: Support replacement character for invalid characters
      def initialize(output_stream, delimiter: $/, encoding: UTF8_ENCODING, strip_non_printable: false)
        @output_stream       = output_stream
        @delimiter           = delimiter.encode(encoding) if delimiter && encoding
        @encoding            = encoding
        @strip_non_printable = strip_non_printable
      end

      # Write a line to the output stream
      #
      # Example:
      #   IOStreams.line_writer('a.txt') do |stream|
      #     stream << 'first line' << 'second line'
      #   end
      def <<(record)
        write(record)
        self
      end

      # Write a line to the output stream followed by the delimiter.
      # Returns [Integer] the number of bytes written.
      #
      # Example:
      #   IOStreams.line_writer('a.txt') do |stream|
      #     count = stream.write('first line')
      #     puts "Wrote #{count} bytes to the output file, including the delimiter"
      #   end
      def write(record)
        chunk = record.to_s
        chunk.gsub!(NOT_PRINTABLE, '') if strip_non_printable
        count = output_stream.write((encoding ? chunk.encode(encoding) : chunk))
        count += output_stream.write(delimiter) if delimiter
        count
      end

      private

      attr_reader :output_stream
    end
  end
end
