module IOStreams
  module Line
    class Writer < IOStreams::Writer
      attr_reader :delimiter

      # Write a line at a time to a stream.
      def self.stream(output_stream, **args)
        # Pass-through if already a line writer
        return yield(output_stream) if output_stream.is_a?(self.class)

        yield new(output_stream, **args)
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
      def initialize(output_stream, delimiter: $/, original_file_name: nil)
        super(output_stream)
        @delimiter = delimiter
      end

      # Write a line to the output stream
      #
      # Example:
      #   IOStreams.path('a.txt').writer(:line) do |stream|
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
      #   IOStreams.path('a.txt').writer(:line) do |stream|
      #     count = stream.write('first line')
      #     puts "Wrote #{count} bytes to the output file, including the delimiter"
      #   end
      def write(data)
        output_stream.write(data.to_s + delimiter)
      end
    end
  end
end
