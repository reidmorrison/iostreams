# frozen_string_literal: true

module IOStreams
  module Line
    class Writer < IOStreams::Writer
      attr_reader :delimiter

      # Returns [Array<Symbol>] the options that the writer accepts, see #initialize, which are the options of each call
      # that writes lines, see `IOStreams::Stream#writer`, which raises for any other.
      def self.option_names
        %i[delimiter]
      end

      # Write a line at a time to a stream.
      def self.stream(output_stream, **)
        yield new(output_stream, **)
      end

      # Returns [String] the delimiter written after every line when none is supplied.
      def self.default_delimiter
        $/
      end

      # Raises ArgumentError for an option that #initialize does not accept, or a delimiter that is not a String, so that
      # the caller can check before it opens its output, which would replace an existing file.
      def self.check(delimiter: nil)
        return if delimiter.nil? || delimiter.is_a?(String)

        raise(ArgumentError, "Invalid delimiter #{delimiter.inspect}: supply the String written after every line")
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
      #     Default: nil, which writes `.default_delimiter`, "\n".
      def initialize(output_stream, delimiter: nil)
        super(output_stream)
        self.class.check(delimiter: delimiter)
        @delimiter = delimiter.nil? ? self.class.default_delimiter : delimiter
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

      # Returns [String] the class and the delimiter written after each line, rather than every instance variable, such
      # as the stream that it writes, so that irb, which displays what a writer block returns, shows what the
      # documentation describes.
      def inspect
        "#<#{self.class.name} delimiter=#{delimiter.inspect}>"
      end
    end
  end
end
