# frozen_string_literal: true

module IOStreams
  module Encode
    class Writer < IOStreams::Writer
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
        @converter          = Converter.new(encoding: external, replace: replace)
        @cleaner            = Cleaner.new(cleaner, replace: replace) unless cleaner.nil?
      end

      # Write a line to the output stream
      #
      # Example:
      #   IOStreams.path('a.txt').encoding('UTF-8').writer do |stream|
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
      #   IOStreams.path('a.txt').encoding('UTF-8').writer do |stream|
      #     count = stream.write('first line')
      #     puts "Wrote #{count} bytes to the output file"
      #   end
      #
      # Binary data, for example when copying a file, is treated as already being in the requested encoding.
      # A multi-byte character that is split across two writes is written by the second write.
      def write(data)
        return 0 if data.nil?

        block = @converter.convert(data.to_s)
        @converter.raise_invalid
        write_block(block)
      end

      # Writes a multi-byte character still held back at the end of the data, after replacing it when it is incomplete.
      # Raises IOStreams::Errors::InvalidEncoding for an incomplete character without `replace`.
      def finish
        block = @converter.finish
        write_block(block) if block
      end

      private

      def write_block(block)
        block = @cleaner.call(block) if @cleaner
        @output_stream.write(block)
      end
    end
  end
end
