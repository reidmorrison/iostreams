module IOStreams
  # Zip compression: reads a file within a zip file, and writes a zip file that contains one file.
  module Zip
    autoload :Reader, "io_streams/zip/reader"
    autoload :Writer, "io_streams/zip/writer"

    # Returns [Class] the class that reads a zip file.
    def self.reader_class
      Reader
    end

    # Returns [Class] the class that writes a zip file.
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
