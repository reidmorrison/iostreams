module IOStreams
  # Converts text to an encoding, and optionally cleanses it.
  module Encode
    extend StreamFormat

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

    # Returns [true|false] whether data in this format is compressed.
    def self.compressed?
      false
    end

    # Returns [true|false] whether data in this format is encrypted.
    def self.encrypted?
      false
    end
  end
end
