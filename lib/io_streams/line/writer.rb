module IOStreams
  module Line
    class Writer < IOStreams::Writer
      attr_reader :delimiter

      # Write a line at a time to a stream.
      def self.stream(output_stream, **args, &block)
        # Pass-through if already a line writer
        output_stream.is_a?(self.class) ? block.call(output_stream) : new(output_stream, **args, &block)
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
        super(output_stream)
        @delimiter = delimiter
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
        output_stream.write(data.to_s + delimiter)
      end
    end
  end
end
