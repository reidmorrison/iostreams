# frozen_string_literal: true

module IOStreams
  # Zip compression: reads a file within a zip file, and writes a zip file that contains one file.
  module Zip
    extend StreamFormat

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

    # Returns [String] the supplied name of a file within a zip file in UTF-8, the encoding that a zip file names its
    # files in, since `zip_kit` writes the bytes of a name as UTF-8, or nil when it is not valid in its encoding, or
    # holds a character that UTF-8 does not have, or is in an encoding that Ruby cannot convert to UTF-8. A binary name
    # is read as UTF-8.
    def self.utf8_entry_name(name)
      convert_entry_name(name)
    rescue EncodingError
      nil
    end

    # Returns [String] why the supplied name cannot name a file within a zip file, see .utf8_entry_name, such as
    # "it is not valid UTF-8", or nil when it can.
    def self.entry_name_problem(name)
      convert_entry_name(name)
      nil
    rescue Encoding::ConverterNotFoundError
      "Ruby cannot convert #{name.encoding} to UTF-8"
    rescue Encoding::UndefinedConversionError
      "it holds a character that UTF-8 does not have"
    rescue EncodingError
      "it is not valid #{name.encoding == Encoding::BINARY ? Encoding::UTF_8 : name.encoding}"
    end

    # Returns [String] the supplied name in UTF-8, reading a binary name as UTF-8, and raises the `EncodingError` of
    # the conversion when it cannot be converted, and `Encoding::InvalidByteSequenceError` before converting a name
    # that is not valid in its encoding, since converting UTF-8 to UTF-8 does not check it.
    def self.convert_entry_name(name)
      text = name.encoding == Encoding::BINARY ? name.dup.force_encoding(Encoding::UTF_8) : name
      raise(Encoding::InvalidByteSequenceError) unless text.valid_encoding?

      text.encode(Encoding::UTF_8)
    end
    private_class_method :convert_entry_name
  end
end
