module IOStreams
  module Encode
    class Reader
      attr_reader :encoding, :cleaner

      NOT_PRINTABLE = Regexp.compile(/[^[:print:]|\r|\n]/).freeze
      # Builtin strip options to apply after encoding the read data.
      CLEANSE_RULES = {
        # Strips all non printable characters
        printable: -> (data) { data.gsub!(NOT_PRINTABLE, '') || data }
      }

      # Read a line at a time from a file or stream
      def self.open(file_name_or_io, **args)
        if file_name_or_io.is_a?(String)
          IOStreams::File::Reader.open(file_name_or_io) { |io| yield new(io, **args) }
        else
          yield new(file_name_or_io, **args)
        end
      end

      # Apply encoding conversion when reading a stream.
      #
      # Parameters
      #   input_stream
      #     The input stream that implements #read
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
      def initialize(input_stream, encoding: 'UTF-8', encode_cleaner: nil, encode_replace: nil)
        @input_stream = input_stream
        @cleaner      = self.class.extract_cleaner(encode_cleaner)

        @encoding         = encoding.nil? || encoding.is_a?(Encoding) ? encoding : Encoding.find(encoding)
        @encoding_options = encode_replace.nil? ? {} : {invalid: :replace, undef: :replace, replace: encode_replace}

        # More efficient read buffering only supported when the input stream `#read` method supports it.
        if encode_replace.nil? && !@input_stream.method(:read).arity.between?(0, 1)
          @read_cache_buffer = ''.encode(@encoding)
        else
          @read_cache_buffer = nil
        end
      end

      # Returns [String] data returned from the input stream.
      # Returns [nil] if end of file and no further data was read.
      def read(size = nil)
        block =
          if @read_cache_buffer
            begin
              @input_stream.read(size, @read_cache_buffer)
            rescue ArgumentError
              # Handle arity of -1 when just 0..1
              @read_cache_buffer = nil
              @input_stream.read(size)
            end
          else
            @input_stream.read(size)
          end

        # EOF reached?
        return unless block

        block = block.encode(@encoding, @encoding_options) unless block.encoding == @encoding
        block = @cleaner.call(block) if @cleaner
        block
      end

      private

      def self.extract_cleaner(cleaner)
        return if cleaner.nil?

        case cleaner
        when Symbol
          proc = CLEANSE_RULES[cleaner]
          raise(ArgumentError, "Invalid cleansing rule #{cleaner.inspect}") unless proc
          proc
        when Proc
          cleaner
        end
      end
    end
  end
end
