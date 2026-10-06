module IOStreams
  # Gzip compression.
  module Gzip
    extend StreamFormat

    autoload :Reader, "io_streams/gzip/reader"
    autoload :Writer, "io_streams/gzip/writer"

    # Returns [Class] the class that reads gzip.
    def self.reader_class
      Reader
    end

    # Returns [Class] the class that writes gzip.
    def self.writer_class
      Writer
    end

    # Returns [true|false] whether data in this format is compressed.
    def self.compressed?
      true
    end

    # Returns [true|false] whether data in this format is encrypted.
    def self.encrypted?
      false
    end
  end
end
