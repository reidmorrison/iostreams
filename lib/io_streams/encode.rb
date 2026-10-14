# frozen_string_literal: true

module IOStreams
  # Converts text to an encoding, and optionally cleanses it.
  #
  # The encode stream is built in rather than registered for a file name extension, since file names do not
  # name it. It applies whenever its options are set with `#encoding`, see `IOStreams::Builder::RESERVED_KEYWORDS`.
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

    # Returns [Array<String|Encoding, Encoding|nil>] the external encoding, which the data is stored in, and the
    # internal encoding, which reading converts the text to, from an `encoding` option.
    #
    # Like Ruby's `File.read(name, encoding: "Windows-1252:UTF-8")`, an option of the form "external:internal"
    # converts the text from the external encoding to the internal encoding. Without a `:` the internal
    # encoding is nil, and the text is returned in the external encoding.
    #
    # Raises ArgumentError for an encoding that Ruby does not know.
    def self.external_and_internal(encoding)
      return [encoding, nil] unless encoding.is_a?(String) && encoding.include?(":")

      external, internal = encoding.split(":", 2)
      [Encoding.find(external), Encoding.find(internal)]
    end

    # Raises ArgumentError for the options that the reader or writer of the encode stream would raise for once the
    # text is read or written: an encoding that Ruby does not know, or that is neither a String nor an Encoding, a
    # `replace` that is not a String, or a cleaner that is neither the name of a built-in rule nor a Proc, see
    # `IOStreams::Encode::Cleaner`. So that they raise when they are set, see `IOStreams::Builder#encoding`, and
    # before a writer opens its output, see `IOStreams::StreamFormat#check_stream`, which would replace an existing
    # file, rather than once the data is read or written.
    def self.check(encoding: default_encoding, cleaner: nil, replace: nil)
      unless encoding.nil? || encoding.is_a?(String) || encoding.is_a?(Encoding)
        raise(ArgumentError, "Invalid encoding #{encoding.inspect}: supply the name of an encoding, such as " \
                             "\"UTF-8\" or \"Windows-1252:UTF-8\", or an Encoding")
      end
      unless replace.nil? || replace.is_a?(String)
        raise(ArgumentError, "Invalid replace #{replace.inspect}: supply the String that replaces each invalid character")
      end

      external, _internal = external_and_internal(encoding)
      Encoding.find(external) if external.is_a?(String)
      Cleaner.new(cleaner, replace: replace) unless cleaner.nil?
      nil
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
