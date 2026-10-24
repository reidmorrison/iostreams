# frozen_string_literal: true

module IOStreams
  module Encode
    class Writer < IOStreams::Writer
      include IOStreams::Writable

      def self.option_names
        %i[encoding cleaner replace]
      end

      # Raises ArgumentError for options that #initialize would raise for, see `IOStreams::Encode.check`.
      def self.check(**)
        Encode.check(**)
      end

      # Yields a writer that encodes the data written to the supplied output stream. Once the block returns, including
      # when it leaves early, such as with `break`, a character still held back at the end of the data is written, see
      # #finish, as the data written so far is kept, but not when the block raises, see `IOStreams::Utils.finish_or_abort`.
      def self.stream(output_stream, **)
        writer = new(output_stream, **)
        Utils.finish_or_abort(finish: -> { writer.finish }) { yield(writer) }
      end

      # A writer that encodes the data written to it, and writes it to the supplied output stream.
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
      #     "UTF-16" and "UTF-32", which name no byte order, write text big-endian, after one byte order mark that tells
      #     so, as Ruby writes it, and binary data that starts the text in the byte order that the byte order mark at
      #     its start tells, or without one, big-endian, after a byte order mark, so that the encode reader can read it.
      #
      #     Like Ruby's `File.write`, with "external:internal", such as "Windows-1252:UTF-8", the data is written in
      #     the external encoding, so that the same option can be used to read and to write a file.
      #
      #   replace: [String]
      #     The character to replace with when a character is invalid, or cannot be converted to the target encoding.
      #     nil: Don't replace any invalid characters. IOStreams::Errors::InvalidEncoding, an
      #          Encoding::UndefinedConversionError, is raised with the byte offset of the invalid character.
      #     Default: nil
      #
      #   cleaner: [nil|symbol|Proc]
      #     Cleanse data read from the input stream.
      #     nil:           No cleansing
      #     :printable Cleanse all non-printable characters except \r and \n
      #     Proc/lambda    Proc to call after every read to cleanse the data
      #     Default: nil
      def initialize(output_stream, encoding: Encode.default_encoding, cleaner: nil, replace: nil)
        super(output_stream)

        external, _internal = Encode.external_and_internal(encoding)
        @replace            = replace
        @cleaner            = Encode.cleaner(cleaner: cleaner, replace: replace)
        # The encodings of the byte orders of "UTF-16" or "UTF-32", while the first data, which decides the byte order
        # that the text is written in, is still to be written, see #start_text.
        @byte_orders        = Encode.byte_order_encodings(external)
        @converter          = Converter.new(encoding: external, replace: replace) unless @byte_orders
      end

      # Writes a multi-byte character still held back at the end of the data, after replacing it when it is incomplete.
      # Raises IOStreams::Errors::InvalidEncoding for an incomplete character without `replace`.
      def finish
        write_start if @start
        block = @converter&.finish
        write_block(block) if block
      end

      private

      # Encodes the data and writes it to the output stream, see `IOStreams::Writable`, which writes `#write`, `#<<`,
      # `#print`, `#puts` and `#printf` through it. Returns [Integer] the number of bytes written to the output stream.
      #
      # Binary data, for example when copying a file, is treated as already being in the requested encoding.
      # A multi-byte character that is split across two writes is written by the second write.
      def write_data(data)
        data = start_text(data) if @byte_orders
        return 0 if data.nil?

        block = @converter.convert(data)
        @converter.raise_invalid
        write_block(block)
      end

      # Returns [String] the first data of "UTF-16" or "UTF-32" text, once it decides the byte order that the text is
      # written in, see #start_byte_order, or nil while it is held back: binary data, the bytes of text in this encoding,
      # such as when copying a file, that is shorter than a byte order mark, until more is written, or the text ends.
      #
      # Binary data is written in the byte order that the byte order mark at its start tells, which it already starts
      # with, and other text big-endian, as Ruby writes it. So is binary data without a byte order mark, as Unicode
      # reads such text, after a byte order mark that tells so, which the encode reader needs to read it.
      def start_text(data)
        return if data.empty?

        unless data.encoding == Encoding::BINARY
          write_start if @start
          start_byte_order(nil) if @byte_orders
          return data
        end

        data   = @start + data if @start
        @start = data.bytesize < Encode.byte_order_mark(@byte_orders.first).bytesize ? data : nil
        return if @start

        start_byte_order(Encode.byte_order(@byte_orders, data))
        data
      end

      # Writes the text in the supplied byte order, the one that the byte order mark at the start of binary data tells,
      # or when nil, big-endian, after a byte order mark that tells so, see #write_block.
      def start_byte_order(byte_order)
        @start_encoding  = BYTE_ORDERS.key(@byte_orders)
        @converter       = Converter.new(encoding: byte_order || @byte_orders.first, replace: @replace)
        @byte_order_mark = Encode.byte_order_mark(@converter.encoding) unless byte_order
        @byte_orders     = nil
      end

      # Writes the binary data held back at the start of the text, which is shorter than a byte order mark, so has
      # none, big-endian, see #start_text.
      def write_start
        start  = @start
        @start = nil
        start_byte_order(nil)
        write_data(start)
      end

      # Writes the block, after the byte order mark of "UTF-16" or "UTF-32" when it is the first text written, since
      # Ruby writes one at the start of each String that it converts to them, rather than once at the start of the text.
      #
      # The block that starts that text, with its byte order mark, is tagged with "UTF-16" or "UTF-32", as Ruby tags
      # such text, and the rest with the encoding of its byte order, so that an output stream that converts the text
      # written to it, such as `File.open(name, "w:UTF-16")`, reads the mark as one, rather than as a character.
      def write_block(block)
        block = @cleaner.call(block) if @cleaner
        if @start_encoding && !block.empty?
          block            = (@byte_order_mark ? @byte_order_mark + block : block.dup).force_encoding(@start_encoding)
          @start_encoding  = nil
          @byte_order_mark = nil
        end
        @output_stream.write(block)
      end
    end
  end
end
