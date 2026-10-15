# frozen_string_literal: true

module IOStreams
  # Zstandard compression, using the `zstd-ruby` gem, or the `zstd-jni` jar on JRuby.
  #
  # On MRI the reader and writer are built on `Zstd::StreamingDecompress` and `Zstd::StreamingCompress`,
  # rather than `Zstd::StreamReader` and `Zstd::StreamWriter`, which the zstd-ruby README marks as
  # experimental and subject to API changes:
  # https://github.com/SpringMT/zstd-ruby#stream-writer-and-reader-wrapper
  module Zstd
    extend StreamFormat

    autoload :Jni,    "io_streams/zstd/jni"
    autoload :Native, "io_streams/zstd/native"
    autoload :Reader, "io_streams/zstd/reader"
    autoload :Writer, "io_streams/zstd/writer"

    # Returns [Module] the zstd library for this Ruby, which supplies the `decoder` and `encoder`
    # that the reader and writer use: `zstd-jni` on JRuby, which cannot load the `zstd-ruby` C extension,
    # and `zstd-ruby` otherwise.
    def self.library
      defined?(JRuby) ? Jni : Native
    end

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

    # Returns [RuntimeError] the error for data that is not valid zstd, for the supplied reason, tagged as
    # `IOStreams::Errors::Corrupt`. It is a RuntimeError, which `zstd-ruby` raises itself, so that the decoder of every
    # library raises the same class.
    def self.corrupt(reason)
      Errors::Corrupt.tag(RuntimeError.new("zstd decompress error: #{reason}"))
    end
  end
end
