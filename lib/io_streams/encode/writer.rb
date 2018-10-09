module IOStreams
  module Encode
    class Writer
      attr_reader :encoding, :cleaner

      # Write a line at a time to a file or stream
      def self.open(file_name_or_io, **args)
        if file_name_or_io.is_a?(String)
          IOStreams::File::Writer.open(file_name_or_io) { |io| yield new(io, **args) }
        else
          yield new(file_name_or_io, **args)
        end
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
      #   encode_replace: [String]
      #     The character to replace with when a character cannot be converted to the target encoding.
      #     nil: Don't replace any invalid characters. Encoding::UndefinedConversionError is raised.
      #     Default: nil
      #
      #   encode_cleaner: [nil|symbol|Proc]
      #     Cleanse data read from the input stream.
      #     nil:           No cleansing
      #     :printable Cleanse all non-printable characters except \r and \n
      #     Proc/lambda    Proc to call after every read to cleanse the data
      #     Default: nil
      def initialize(output_stream, encoding: 'UTF-8', encode_cleaner: nil, encode_replace: nil)
        @output_stream = output_stream
        @cleaner       = ::IOStreams::Encode::Reader.send(:extract_cleaner, encode_cleaner)

        @encoding         = encoding.nil? || encoding.is_a?(Encoding) ? encoding : Encoding.find(encoding)
        @encoding_options = encode_replace.nil? ? {} : {invalid: :replace, undef: :replace, replace: encode_replace}
      end

      # Write a line to the output stream
      #
      # Example:
      #   IOStreams.writer('a.txt', encoding: 'UTF-8') do |stream|
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
      #   IOStreams.writer('a.txt', encoding: 'UTF-8') do |stream|
      #     count = stream.write('first line')
      #     puts "Wrote #{count} bytes to the output file, including the delimiter"
      #   end
      def write(data)
        return 0 if data.nil?

        data  = data.to_s
        block = data.encoding == @encoding ? data : data.encode(@encoding, @encoding_options)
        block = @cleaner.call(block) if @cleaner
        @output_stream.write(block)
      end
    end
  end
end
