# frozen_string_literal: true

module IOStreams
  module Encode
    # Reads the text of the input stream in an encoding, converting it to another encoding, see #initialize, like an IO
    # that reads text in an encoding, such as `File.open(name, "r:Windows-1252:UTF-8")`: `#read`, `#readpartial`,
    # `#gets`, `#readline`, `#readlines`, `#each_line` and `#eof?`, see `IOStreams::ChunkReader`. So that code that
    # reads lines from the stream that `#reader` supplies, such as `CSV.new(io)`, works whether or not an encoding is set.
    #
    # Unlike an IO, which reads bytes with a length, `#read` with a length and `#readpartial` read text too, in whole
    # characters, which a reader of lines, such as `IOStreams::Line::Reader`, relies on.
    class Reader < IOStreams::Reader
      include ChunkReader

      # The encodings of the text whose byte order mark is removed, see #remove_byte_order_mark: UTF-8, and the encodings
      # of the byte orders of UTF-16 and UTF-32, one of which text in "UTF-16" or "UTF-32" is read in, see
      # #read_byte_order.
      BYTE_ORDER_MARK_ENCODINGS = [Encoding::UTF_8, *BYTE_ORDERS.values.flatten].freeze

      # The number of bytes read from the input stream at a time, apart from a read with a length, see #read.
      BLOCK_SIZE = 65_536

      def self.option_names
        %i[encoding cleaner replace]
      end

      # Raises ArgumentError for options that #initialize would raise for, see `IOStreams::Encode.check`.
      def self.check(**)
        Encode.check(**)
      end

      # Yields a reader that decodes the data read from the supplied input stream, see #initialize.
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
      #     The data read is the contents of a file or stream, so it is treated as already being in this encoding,
      #     whatever encoding the input stream tags it with. So its characters are kept and only invalid characters
      #     are replaced, or raise an error.
      #
      #     Like Ruby's `File.read`, "external:internal", such as "Windows-1252:UTF-8", reads the data in the external
      #     encoding and converts it to the internal encoding. A character that the internal encoding does not have
      #     raises Encoding::UndefinedConversionError, unless `replace` is supplied.
      #
      #     When reading UTF-8, UTF-16LE, UTF-16BE, UTF-32LE or UTF-32BE, a byte order mark at the start of the data is
      #     removed. "UTF-16" and "UTF-32", which name no byte order, read the data in the byte order that the byte
      #     order mark at its start tells, such as UTF-16LE for "\xFF\xFE", whose mark is removed too, as Ruby reads
      #     "BOM|UTF-16", so the text read without an internal encoding is in the encoding of that byte order. Data that
      #     does not start with one raises IOStreams::Errors::InvalidEncoding, as Ruby raises, unless `replace` is
      #     supplied, which reads it big-endian, as Unicode reads such text. "UTF-16:UTF-16" names the encoding of the
      #     text twice, so it is read as "UTF-16".
      #
      #   replace: [String]
      #     The character to replace with when a character is invalid, or cannot be converted to the target encoding.
      #     nil: Don't replace any invalid characters. IOStreams::Errors::InvalidEncoding, an
      #          Encoding::UndefinedConversionError, is raised with the byte offset of the invalid character, by every
      #          read that reaches it. A read with a length first returns the text before it, and the next read raises.
      #     Default: nil
      #
      #   cleaner: [nil|symbol|Proc]
      #     Cleanse data read from the input stream.
      #     nil:           No cleansing
      #     :printable Cleanse all non-printable characters except \r and \n
      #     Proc/lambda    Proc to call after every read to cleanse the data
      #     Default: nil
      def initialize(input_stream, encoding: Encode.default_encoding, cleaner: nil, replace: nil)
        super(input_stream)

        external, @internal = Encode.external_and_internal(encoding)
        # The text is not converted to the encoding that it is in, such as "UTF-16:UTF-16", see #read_as.
        @internal           = nil if @internal == external
        @replace            = replace
        @transcode_options  = replace.nil? ? {} : {invalid: :replace, undef: :replace, replace: replace}
        @cleaner            = Cleaner.new(cleaner, replace: replace) unless cleaner.nil?
        # The encodings of the byte orders of "UTF-16" or "UTF-32", while the byte order mark at the start of the data,
        # which tells which one it is in, is still to be read, see #read_byte_order.
        @byte_orders        = Encode.byte_order_encodings(external)
        read_as(external) unless @byte_orders

        # More efficient read buffering only supported when the input stream `#read` method supports it.
        # Binary, since `IO#read` keeps the encoding of the buffer that it reads into.
        @read_cache_buffer = (String.new(encoding: Encoding::BINARY) unless @input_stream.method(:read).arity.between?(0, 1))
        @block_size        = BLOCK_SIZE
      end

      # Returns [String] the text of upto `length` bytes, or the rest of the text, see `IOStreams::ChunkReader#read`.
      #
      # A read with a length reads the input stream in blocks of that length, so that the data of the lines that
      # `IOStreams::Line::Reader` reads in blocks of its `buffer_size` is read in blocks of that size.
      def read(length = nil, outbuf = nil)
        @block_size = length if length.is_a?(Integer) && length.positive?
        super
      ensure
        @block_size = BLOCK_SIZE
      end

      # Returns [true|false] whether the input stream has been closed, such as the file that a path reads once the block
      # that reads it returns, after which every read raises IOError, see `IOStreams::ChunkReader`.
      def closed?
        @input_stream.respond_to?(:closed?) && @input_stream.closed?
      end

      private

      # Returns [Encoding] the encoding of the text that is read, see `IOStreams::ChunkReader`: the internal encoding, or
      # the encoding of the data, or binary when the data is read as it is. The encoding of the data of "UTF-16" or
      # "UTF-32" is that of the byte order that its byte order mark tells, which is read first, so that it is only read
      # without an internal encoding, see #read_byte_order.
      def chunk_encoding
        return @internal if @internal

        read_byte_order if @byte_orders
        @converter.encoding || Encoding::BINARY
      end

      # Returns [String] the text of the next block of the input stream, in whole characters, or nil at its end, see
      # `IOStreams::ChunkReader`.
      #
      # Raises IOStreams::Errors::InvalidEncoding for data that is not valid, once the text before it has been returned,
      # and again each time that it is called after, since the converter keeps the error.
      def next_chunk
        read_byte_order if @byte_orders
        block  = @start || read_block
        @start = nil
        return text(@converter.convert(block)) if block

        text(@converter.finish) || finish_transcoder
      end

      # Reads the data in the supplied encoding, converted to the internal encoding unless it is the same one.
      def read_as(encoding)
        @converter       = Converter.new(encoding: encoding, replace: @replace)
        @internal        = nil if @internal == @converter.encoding
        # The byte order mark in the encoding of the data, while the start of the data, where Unicode text can begin
        # with one, is still to be read.
        @byte_order_mark = byte_order_mark(@converter.encoding)
        # Ruby calls an encoding that keeps state from one character to the next, such as ISO-2022-JP, whose escape
        # sequences switch the character set of the characters after them, a dummy encoding, as it does "UTF-16" and
        # "UTF-32", whose byte order mark starts the text. So data is converted from or to one by a single converter,
        # which keeps that state from one block to the next, see #transcode.
        return unless @internal && (@converter.encoding&.dummy? || @internal.dummy?)

        @transcoder = Encoding::Converter.new(@converter.encoding, @internal, **@transcode_options)
        # The number of bytes of the data that the transcoder has converted, for the byte offset of invalid data.
        @transcoded = 0
      end

      # Reads data in "UTF-16" or "UTF-32" in the encoding of the byte order that the byte order mark at its start tells,
      # such as UTF-16LE for "\xFF\xFE", see `IOStreams::Encode.byte_order`, whose byte order mark is then removed, as
      # Ruby removes it. Reads only the bytes of a byte order mark, which it keeps for #next_chunk, so that a read of no
      # text, such as `read(0)`, reads no more. Data without any bytes is read big-endian, which has no text to read.
      #
      # Data that does not start with a byte order mark is read big-endian with `replace`, as Unicode reads such text,
      # and otherwise raises IOStreams::Errors::InvalidEncoding, which Ruby also raises, since only the mark tells its
      # byte order, again each time that it is called after.
      def read_byte_order
        raise(@byte_order_error) if @byte_order_error

        size  = Encode.byte_order_mark(@byte_orders.first).bytesize
        start = String.new(encoding: Encoding::BINARY)
        while start.bytesize < size && (block = read_block(size - start.bytesize))
          start << block
        end
        encoding = Encode.byte_order(@byte_orders, start)
        raise(@byte_order_error = missing_byte_order_mark(start)) unless encoding || @replace || start.empty?

        @start = start unless start.empty?
        read_as(encoding || @byte_orders.first)
        @byte_orders = nil
      end

      # Returns [IOStreams::Errors::InvalidEncoding] the error for data in "UTF-16" or "UTF-32" that does not start with
      # a byte order mark, see #read_byte_order, whose first bytes are supplied.
      def missing_byte_order_mark(bytes)
        encoding = BYTE_ORDERS.key(@byte_orders)
        Errors::InvalidEncoding.new(
          "The #{encoding} text does not start with a byte order mark, which tells its byte order, so supply " \
          "#{@byte_orders.reverse.join(' or ')} instead: #{bytes.dump}",
          byte_offset: 0, error_char: bytes, source_encoding: Encoding::BINARY, destination_encoding: encoding
        )
      end

      # Returns [String] the whole characters that the converter returned, without the byte order mark at the start of
      # the data, in the internal encoding, and cleansed. Returns nil at the end of the data.
      def text(data)
        return if data.nil?

        data = remove_byte_order_mark(data) if @byte_order_mark && !data.empty?
        # Data that is not converted, such as with `encoding: "BINARY"`, is the block that was read, which can be
        # the buffer that the next block is read into.
        data = data.dup if data.equal?(@read_cache_buffer)
        data = to_internal(data) if @internal
        data = @cleaner.call(data) if @cleaner
        data
      end

      # Returns [String] the data in the internal encoding. The converter returns whole characters, so each block is
      # converted on its own, apart from the data of a dummy encoding, or into one, see #transcode.
      def to_internal(data)
        @transcoder ? transcode(data) : data.encode(@internal, **@transcode_options)
      end

      # Returns [String] the data in the internal encoding, converted by the converter that keeps the state of a dummy
      # encoding from one block to the next, see #read_as, which holds back a character or an escape sequence that the
      # data ends within for the next block, unless the data is `final`.
      #
      # Raises IOStreams::Errors::InvalidEncoding for data that is not valid, with its byte offset, as the converter of
      # the data does for the other encodings, and Encoding::UndefinedConversionError for a character that the internal
      # encoding does not have, as String#encode does for the other encodings, once the text before it has been
      # returned, and again each time after.
      def transcode(data, final: false)
        raise(@transcode_error) if @transcode_error

        source = data.dup
        text   = String.new(encoding: @internal)
        result = @transcoder.primitive_convert(source, text, nil, nil, partial_input: !final)
        @transcoded     += data.bytesize - source.bytesize
        @transcode_error = transcode_error(result)
        raise(@transcode_error) if @transcode_error && text.empty?

        text
      end

      # Returns the error for the data that the transcoder stopped at, see #transcode, or nil when it converted all of
      # the data: IOStreams::Errors::InvalidEncoding for data that is not valid, or Encoding::UndefinedConversionError
      # for a character that the internal encoding does not have.
      def transcode_error(result)
        return @transcoder.last_error if result == :undefined_conversion
        return unless %i[invalid_byte_sequence incomplete_input].include?(result)

        _result, source_encoding, _destination, error_bytes, readagain_bytes = @transcoder.primitive_errinfo
        Errors::InvalidEncoding.new(
          "#{error_bytes.b.dump} is not valid #{source_encoding}",
          byte_offset: @transcoded - error_bytes.bytesize - readagain_bytes.bytesize, error_char: error_bytes.b,
          source_encoding: Encoding::BINARY, destination_encoding: @converter.encoding
        )
      end

      # Returns [String] the end of the text that the converter of a dummy encoding still holds once the data has been
      # read, in the internal encoding, and cleansed, or nil when it holds none, see #transcode. Raises
      # IOStreams::Errors::InvalidEncoding when the data ends within a character or an escape sequence, unless
      # `replace` is supplied, as converting the whole of the data with String#encode raises.
      def finish_transcoder
        return if @transcoder.nil?

        rest        = transcode(String.new, final: true)
        @transcoder = nil
        return if rest.empty?

        @cleaner ? @cleaner.call(rest) : rest
      end

      # Returns [String] the byte order mark in the encoding of the data, or nil for an encoding whose byte order mark is
      # not removed, see BYTE_ORDER_MARK_ENCODINGS.
      def byte_order_mark(encoding)
        Encode.byte_order_mark(encoding) if BYTE_ORDER_MARK_ENCODINGS.include?(encoding)
      end

      # Returns [String] the first characters of the data without a byte order mark. Since the converter returns whole
      # characters, a byte order mark split across reads is in the first data that it returns.
      def remove_byte_order_mark(data)
        mark             = @byte_order_mark
        @byte_order_mark = nil
        data.start_with?(mark) ? data.byteslice(mark.bytesize..) : data
      end

      # Returns [String] the next block of the input stream, of upto `length` bytes, as binary data, or [nil] at the end
      # of the stream.
      #
      # The data read is bytes, whatever encoding the input stream tags it with, such as `Encoding.default_external`
      # when the whole of a gzip file is read, so that it is treated the same whichever streams it was read through.
      def read_block(length = @block_size)
        block = read_input(length)
        block.nil? || block.encoding == Encoding::BINARY ? block : block.b
      end

      def read_input(length)
        return @input_stream.read(length) unless @read_cache_buffer

        @input_stream.read(length, @read_cache_buffer)
      rescue ArgumentError
        # Handle arity of -1 when just 0..1
        @read_cache_buffer = nil
        @input_stream.read(length)
      end
    end
  end
end
