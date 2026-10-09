module IOStreams
  # Zstandard compression, using the `zstd-ruby` gem.
  #
  # The reader and writer are built on `Zstd::StreamingDecompress` and `Zstd::StreamingCompress`,
  # rather than `Zstd::StreamReader` and `Zstd::StreamWriter`, which the zstd-ruby README marks as
  # experimental and subject to API changes:
  # https://github.com/SpringMT/zstd-ruby#stream-writer-and-reader-wrapper
  module Zstd
    extend StreamFormat

    autoload :Reader, "io_streams/zstd/reader"
    autoload :Writer, "io_streams/zstd/writer"

    # Returns [Class] the class that reads zstd.
    def self.reader_class
      Reader
    end

    # Returns [Class] the class that writes zstd.
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
