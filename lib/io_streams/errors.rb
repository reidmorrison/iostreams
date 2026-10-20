module IOStreams
  module Errors
    class Error < StandardError
    end

    class InvalidHeader < Error
    end

    class MissingHeader < Error
    end

    class UnknownFormat < Error
    end

    class TypeMismatch < Error
    end

    class CommunicationsFailure < Error
    end

    # When a path is not within any of the allowed paths, see `IOStreams.add_allowed_path`.
    class AccessDenied < Error
    end

    # When the specified delimiter is not found in the supplied stream / file
    class DelimiterNotFound < Error
    end

    # Fixed length line has the wrong length
    class InvalidLineLength < Error
    end

    class ValueTooLong < Error
    end

    # A value that is not one of the type of its field in the schema, such as `"abc"` for an integer,
    # see `IOStreams::Stream#schema`.
    class InvalidValue < Error
    end

    # Text that is not valid in the encoding that it is read or written in, such as bytes that are not valid UTF-8 in
    # a file read with a schema, see `IOStreams::Stream#schema`.
    #
    # It is an `Encoding::UndefinedConversionError`, as the encode stream raises, so that it can be rescued as one.
    #
    # Example:
    #   IOStreams.path("data.csv").schema("people.json").each(:hash) { |hash| p hash }
    #   # => IOStreams::Errors::InvalidEncoding: "\xFF" is not valid UTF-8
    class InvalidEncoding < ::Encoding::UndefinedConversionError
      # Returns [String] the invalid bytes, as binary, like `Encoding::UndefinedConversionError#error_char`.
      attr_reader :error_char

      # Returns [Encoding] the encoding that the invalid bytes were read or written as, binary for data read from a file,
      # and the encoding that they are not valid in, like `Encoding::UndefinedConversionError#source_encoding` and
      # `#destination_encoding`.
      attr_reader :source_encoding, :destination_encoding

      def initialize(message, error_char: nil, source_encoding: nil, destination_encoding: nil)
        @error_char           = error_char
        @source_encoding      = source_encoding
        @destination_encoding = destination_encoding
        super(message)
      end

      # Returns [String] the name of the #source_encoding, such as "ASCII-8BIT", or nil.
      def source_encoding_name
        source_encoding&.name
      end

      # Returns [String] the name of the #destination_encoding, such as "UTF-8", or nil.
      def destination_encoding_name
        destination_encoding&.name
      end
    end

    class MalformedDataError < RuntimeError
      attr_reader :line_number

      def initialize(message, line_number)
        @line_number = line_number
        super("#{message} on line #{line_number}.")
      end
    end

    class InvalidLayout < Error
    end
  end
end
