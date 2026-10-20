module IOStreams
  module Line
    # Reads the lines of a file whose text is UTF-8, but is read without an encoding, as UTF-8 strings, rather than the
    # binary strings that a file is read as without one: the lines of a file with a schema, see
    # `IOStreams::Stream#schema` and `IOStreams::Builder#utf8_text?`, as its rows and records are read.
    #
    # Raises `IOStreams::Errors::InvalidEncoding` for a line that is not valid UTF-8, naming the line that the first
    # invalid character is on, see `IOStreams::Utils.invalid_utf8`.
    class Utf8Reader < Reader
      def readline
        first_line_number = line_number + 1
        line              = super
        return line unless line&.encoding == ::Encoding::BINARY

        # Each line is a String of its own, sliced from the data read, so it is taken as UTF-8 in place.
        line.force_encoding(::Encoding::UTF_8)
        return line if line.valid_encoding?

        raise(IOStreams::Utils.invalid_utf8(line, line_number: first_line_number))
      end
    end
  end
end
