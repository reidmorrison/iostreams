module IOStreams
  # Bzip2 compression, using the `bzip2-ffi` gem.
  module Bzip2
    extend StreamFormat

    autoload :Reader, "io_streams/bzip2/reader"
    autoload :Writer, "io_streams/bzip2/writer"

    # Returns [Class] the class that reads bzip2.
    def self.reader_class
      Reader
    end

    # Returns [Class] the class that writes bzip2.
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
