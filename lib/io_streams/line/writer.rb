module IOStreams
  module Line
    class Writer
      attr_reader :delimiter

      # Write a line at a time to a file or stream
      def self.open(file_name_or_io, **args)
        if file_name_or_io.is_a?(String)
          IOStreams::File::Writer.open(file_name_or_io) { |io| yield new(io, **args) }
        else
          yield new(file_name_or_io, **args)
        end
      end

      # A delimited stream writer that will write to the supplied output stream.
      #
      # The output stream will have the encoding of data written to it.
      # To change the output encoding, use IOStreams::Encode::Writer.
      #
      # Parameters
      #   output_stream
      #     The output stream that implements #write
      #
      #   delimiter: [String]
      #     Add the specified delimiter after every record when writing it
      #     to the output stream
      #     Default: OS Specific. Linux: "\n"
      def initialize(output_stream, delimiter: $/)
        @output_stream = output_stream
        @delimiter     = delimiter
      end

      # Write a line to the output stream
      #
      # Example:
      #   IOStreams.line_writer('a.txt') do |stream|
      #     stream << 'first line' << 'second line'
      #   end
      def <<(data)
        write(data)
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
      def write(data)
        @output_stream.write(data.to_s + delimiter)
      end
    end
  end
end
