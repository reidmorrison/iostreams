module IOStreams
  module Encode
    class Writer < IOStreams::Writer
      def self.option_names
        %i[encoding cleaner replace]
      end

      attr_reader :encoding, :cleaner

      # Write a line at a time to a file or stream
      def self.stream(input_stream, **args)
        writer = new(input_stream, **args)
        result = yield(writer)
        writer.send(:finish)
        result
      end

      # A delimited stream writer that will write to the supplied output stream
      # Written data is encoded prior to writing.
      #
      # Parameters
      #   output_stream
      #     The output stream that implements #write
      #
      #   encoding: [String|Encoding]
      #     Encode returned data with this encoding.
      #     'US-ASCII':   Original 7 bit ASCII Format
      #     'ASCII-8BIT': 8-bit ASCII Format
      #     'UTF-8':      UTF-8 Format
      #     Etc.
      #     Default: 'UTF-8'
      #
      #     Binary data, such as the contents of a file, is treated as already being in this encoding,
      #     so its characters are kept and only invalid characters are replaced, or raise an error.
      #
      #   replace: [String]
      #     The character to replace with when a character is invalid, or cannot be converted to the target encoding.
      #     nil: Don't replace any invalid characters. Encoding::UndefinedConversionError is raised.
      #     Default: nil
      #
      #   cleaner: [nil|symbol|Proc]
      #     Cleanse data read from the input stream.
      #     nil:           No cleansing
      #     :printable Cleanse all non-printable characters except \r and \n
      #     Proc/lambda    Proc to call after every read to cleanse the data
      #     Default: nil
      def initialize(output_stream, encoding: "UTF-8", cleaner: nil, replace: nil)
        super(output_stream)

        @cleaner   = ::IOStreams::Encode::Reader.send(:extract_cleaner, cleaner)
        @encoding  = encoding.nil? || encoding.is_a?(Encoding) ? encoding : Encoding.find(encoding)
        @replace   = replace
        @converter = Converter.new(encoding: @encoding, replace: replace)
      end

      # Write a line to the output stream
      #
      # Example:
      #   IOStreams.path('a.txt').option(:encode, encoding: 'UTF-8').writer do |stream|
      #     stream << 'first line' << 'second line'
      #   end
      def <<(record)
        write(record)
        self
      end

      # Encode data and write it to the output stream.
      # Returns [Integer] the number of bytes written.
      #
      # Example:
      #   IOStreams.path('a.txt').option(:encode, encoding: 'UTF-8').writer do |stream|
      #     count = stream.write('first line')
      #     puts "Wrote #{count} bytes to the output file"
      #   end
      #
      # Binary data, for example when copying a file, is treated as already being in the requested encoding.
      # A multi-byte character that is split across two writes is written by the second write.
      def write(data)
        return 0 if data.nil?

        write_block(@converter.convert(data.to_s))
      end

      private

      # Writes a multi-byte character still held back at the end of the data.
      def finish
        block = @converter.finish
        write_block(block) if block
      end

      def write_block(block)
        block = @cleaner.call(block, @replace) if @cleaner
        @output_stream.write(block)
      end
    end
  end
end
