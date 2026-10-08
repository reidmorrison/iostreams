module IOStreams
  module Encode
    # Converts blocks of data to an encoding, for the encode reader and writer.
    #
    # Binary data, such as the blocks read from a file, has no encoding of its own, so its bytes are
    # treated as already being in the target encoding and are only validated, rather than converted
    # from binary, where every byte above 127 is undefined. Data with another encoding is converted.
    #
    # A multi-byte character can be split across two blocks, so an incomplete character at the end
    # of a block is held back and added to the start of the next block.
    #
    # Data that is not valid in the encoding raises IOStreams::Errors::InvalidEncoding, with the offset of the
    # invalid bytes within all of the data converted. Unless it is in the final data, the valid data before it is
    # returned first, so that for example every whole line before it can be read, and the next call raises.
    class Converter
      # Returns [Encoding] the encoding converted to, or nil when the data is returned unchanged.
      attr_reader :encoding

      # Parameters
      #   encoding: [String|Encoding|nil]
      #     The encoding to convert to, such as "UTF-8". When nil, or binary, the data is returned unchanged.
      #
      #   replace: [String|nil]
      #     Replaces invalid or undefined characters. When nil, invalid characters raise
      #     IOStreams::Errors::InvalidEncoding, and undefined characters raise Encoding::UndefinedConversionError.
      def initialize(encoding:, replace:)
        @encoding         = encoding.nil? || encoding.is_a?(Encoding) ? encoding : Encoding.find(encoding)
        @replace          = replace
        @encoding_options = replace.nil? ? {} : {invalid: :replace, undef: :replace, replace: replace}
        @pending          = nil
        # The number of bytes of the data supplied before the data held back in `@pending`.
        @offset           = 0
        # The error for invalid data, raised by the call after the one that returned the valid data before it.
        @invalid          = nil
      end

      # Returns [String] the supplied data in the target encoding.
      #
      # When `final` is false an incomplete character at the end of the data is held back until the next call.
      def convert(data, final: false)
        return data if @encoding.nil? || @encoding == Encoding::BINARY

        raise_invalid

        if [Encoding::BINARY, @encoding].include?(data.encoding)
          validate(@pending ? @pending + data.b : data.b, final)
        else
          remaining = finish
          converted = data.encode(@encoding, **@encoding_options)
          @offset  += data.bytesize
          remaining ? remaining + converted : converted
        end
      end

      # Returns [String] any incomplete character still held back, after replacing it, or [nil] when there is none.
      # Raises IOStreams::Errors::InvalidEncoding when it is held back and `replace` is nil.
      def finish
        raise_invalid
        return if @pending.nil?

        validate(@pending, true)
      end

      # Raises IOStreams::Errors::InvalidEncoding when the data returned by the last call to #convert was followed by
      # invalid data, for a caller that must not wait for the next call to find out.
      def raise_invalid
        raise(@invalid) if @invalid
      end

      private

      def validate(bytes, final)
        @pending = nil
        unless final
          size = incomplete_size(bytes)
          if size.positive?
            @pending = bytes.byteslice(-size, size)
            bytes    = bytes.byteslice(0, bytes.bytesize - size)
          end
        end

        text     = bytes.force_encoding(@encoding)
        position = @offset
        @offset += text.bytesize
        return text if text.valid_encoding?
        return text.scrub(@replace) unless @replace.nil?

        valid    = valid_prefix(text)
        @invalid = invalid_error(text.byteslice(valid.bytesize..), position + valid.bytesize)
        raise(@invalid) if final || valid.empty?

        valid
      end

      # Returns [String] the valid characters at the start of the text, before its first invalid character.
      def valid_prefix(text)
        size = 0
        text.each_char do |char|
          break unless char.valid_encoding?

          size += char.bytesize
        end
        text.byteslice(0, size)
      end

      # Returns [IOStreams::Errors::InvalidEncoding] the error for the text, which starts with an invalid character.
      def invalid_error(text, byte_offset)
        invalid = nil
        text.scrub do |sequence|
          invalid ||= sequence
          ""
        end
        Errors::InvalidEncoding.new("#{invalid.dump} is not valid #{@encoding}", byte_offset: byte_offset)
      end

      # Returns [Integer] the number of bytes at the end of the data that are the start of an incomplete character.
      def incomplete_size(bytes)
        return incomplete_utf8_size(bytes) if @encoding == Encoding::UTF_8
        return 0 if bytes.dup.force_encoding(@encoding).valid_encoding?

        # Other encodings: the shortest number of trailing bytes whose removal leaves valid data.
        (1..[3, bytes.bytesize].min).find do |size|
          bytes.byteslice(0, bytes.bytesize - size).force_encoding(@encoding).valid_encoding?
        end || 0
      end

      def incomplete_utf8_size(bytes)
        size = bytes.bytesize
        (1..[3, size].min).each do |count|
          byte = bytes.getbyte(size - count)
          # Continuation byte, keep looking for the first byte of the character.
          next if (byte & 0xC0) == 0x80
          return 0 if byte < 0xC0

          length = if byte >= 0xF0
                     4
                   else
                     byte >= 0xE0 ? 3 : 2
                   end
          return length > count ? count : 0
        end
        0
      end
    end
  end
end
