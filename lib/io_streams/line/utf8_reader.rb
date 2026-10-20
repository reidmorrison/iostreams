module IOStreams
  module Line
    # Reads the lines of a file whose text is UTF-8, but is read without an encoding, as UTF-8 strings, rather than the
    # binary strings that a file is read as without one: the lines of a file with a schema, see
    # `IOStreams::Stream#schema`, as its rows and records are read.
    #
    # Raises `IOStreams::Errors::InvalidEncoding` for a line that is not valid UTF-8, see `IOStreams::Utils.utf8`.
    class Utf8Reader < Reader
      def readline
        line = super
        line && IOStreams::Utils.utf8(line)
      end
    end
  end
end
