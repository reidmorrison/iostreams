module IOStreams
  module Encode
    class Reader < IOStreams::Reader
      def self.option_names
        %i[encoding cleaner replace]
      end

      attr_reader :encoding, :cleaner

      NOT_PRINTABLE = /[^[:print:]|\r\n]/
      # Builtin strip options to apply after encoding the read data.
      CLEANSE_RULES = {
        # Strips all non printable characters
        printable:             ->(data, _) { data.gsub!(NOT_PRINTABLE, "") || data },
        # Replaces non printable characters with the value specified in the `replace` option.
        replace_non_printable: ->(data, replace) { data.gsub!(NOT_PRINTABLE, replace || "") || data }
      }.freeze

      # Read a line at a time from a file or stream
      def self.stream(input_stream, **args)
        yield new(input_stream, **args)
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
      #   replace: [String]
      #     The character to replace with when a character cannot be converted to the target encoding.
      #     nil: Don't replace any invalid characters. Encoding::UndefinedConversionError is raised.
      #     Default: nil
      #
      #   cleaner: [nil|symbol|Proc]
      #     Cleanse data read from the input stream.
      #     nil:           No cleansing
      #     :printable Cleanse all non-printable characters except \r and \n
      #     Proc/lambda    Proc to call after every read to cleanse the data
      #     Default: nil
      def initialize(input_stream, encoding: "UTF-8", cleaner: nil, replace: nil)
        super(input_stream)

        @cleaner          = self.class.extract_cleaner(cleaner)
        @encoding         = encoding.nil? || encoding.is_a?(Encoding) ? encoding : Encoding.find(encoding)
        @encoding_options = replace.nil? ? {} : {invalid: :replace, undef: :replace, replace: replace}
        @replace          = replace

        # More efficient read buffering only supported when the input stream `#read` method supports it.
        @read_cache_buffer = ("".encode(@encoding) if replace.nil? && !@input_stream.method(:read).arity.between?(0, 1))
      end

      # Returns [String] data returned from the input stream.
      # Returns [nil] if end of file and no further data was read.
      #
      # As IO#read does, the data is read into the supplied buffer, which is returned, and which is empty once the end
      # of the file was reached, so that `IO.copy_stream`, which supplies one, can read it, such as for a copy without a
      # mode from a stream with an encoding.
      def read(size = nil, outbuf = nil)
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
        unless block
          outbuf&.clear
          return
        end

        block = text(block, size) if text_bytes?(block)
        block = block.encode(@encoding, **@encoding_options) unless block.encoding == @encoding
        block = @cleaner.call(block, @replace) if @cleaner
        return outbuf.replace(block) if outbuf

        # A copy of the buffer that it reads into, which the next read writes over, so that the caller keeps the data.
        block.equal?(@read_cache_buffer) ? block.dup : block
      end

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

      private

      # Returns [true|false] whether the binary data that a read returned can hold the bytes of text in the encoding,
      # rather than text to convert into it, see #text. Without `replace:` it reads into a buffer of the encoding, whose
      # bytes are then the text, as `IO#read` keeps the encoding of the buffer that it is supplied for a read of a length.
      # A stream that returns the bytes as binary instead, since its `#read` takes no buffer, as `Zlib::GzipReader` on
      # JRuby, or makes the buffer binary, as `Bzip2::FFI::Reader` does, holds the same text, as does a read of the whole
      # of the data, which `IO#read` returns as binary, and converting it from binary would reject each character that is
      # not ASCII. With `replace:` it is converted from binary, replacing each character that is not ASCII, as before.
      def text_bytes?(block)
        @replace.nil? && block.encoding == Encoding::BINARY
      end

      # Returns [String] the bytes of the binary data as text in the encoding, in a String of its own, rather than the
      # String that the input stream returned, which it can still hold, such as a buffer that it reuses. Those of a read
      # of a length are taken as they are, as `IO#read` reads them into a buffer of the encoding, since a character can
      # be split between two reads. The whole of the data is taken only when it is valid in the encoding; otherwise the
      # data itself is returned, which is converted from binary, raising for each character that is not ASCII, as before.
      def text(block, size)
        text = ::String.new(block, encoding: @encoding)
        size.nil? && !text.valid_encoding? ? block : text
      end
    end
  end
end
