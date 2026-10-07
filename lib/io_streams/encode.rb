module IOStreams
  # Converts text to an encoding, and optionally cleanses it.
  module Encode
    extend StreamFormat

    autoload :Cleaner, "io_streams/encode/cleaner"
    autoload :Converter, "io_streams/encode/converter"
    autoload :Reader, "io_streams/encode/reader"
    autoload :Writer, "io_streams/encode/writer"

    # Returns [Class] the class that converts text as it is read.
    def self.reader_class
      Reader
    end

    # Returns [Class] the class that converts text as it is written.
    def self.writer_class
      Writer
    end

    # Returns [Encoding] the encoding of text that is read or written without an `encoding` option.
    def self.default_encoding
      Encoding::UTF_8
    end

    # Returns [true|false] whether data in this format is compressed.
    def self.compressed?
      false
    end

    # Returns [true|false] whether data in this format is encrypted.
    def self.encrypted?
      false
    end

    # Returns [false] since file names do not name this stream: it converts the text that the application reads
    # or writes, so it applies whenever its options are set with `#option`, ahead of the streams named by the
    # file name. See `IOStreams::StreamFormat#file_name_extension?`.
    def self.file_name_extension?
      false
    end
  end
end
