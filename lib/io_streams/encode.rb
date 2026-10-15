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

    # The byte order mark that some programs write at the start of Unicode text, such as Excel at the start of a "CSV
    # UTF-8" file, and Windows programs at the start of UTF-16LE "Unicode Text".
    BYTE_ORDER_MARK = "\uFEFF"

    # The encodings whose text starts with a byte order mark that tells its byte order, "UTF-16" and "UTF-32", which
    # Ruby calls dummy encodings, and the encodings of their byte orders, big-endian first, which Ruby writes them in.
    BYTE_ORDERS = {
      Encoding::UTF_16 => [Encoding::UTF_16BE, Encoding::UTF_16LE].freeze,
      Encoding::UTF_32 => [Encoding::UTF_32BE, Encoding::UTF_32LE].freeze
    }.freeze

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

    # Returns [Array<Encoding>] the encodings of the byte orders of text in the supplied encoding, big-endian first,
    # when it starts with a byte order mark that tells its byte order, "UTF-16" or "UTF-32", see BYTE_ORDERS, otherwise
    # nil. Ruby converts such text one String at a time, writing a byte order mark at the start of each String, and
    # reading one only at its start, so the encode stream reads and writes it in the encoding of its byte order.
    def self.byte_order_encodings(encoding)
      BYTE_ORDERS[encoding.is_a?(String) ? Encoding.find(encoding) : encoding]
    end

    # Raises ArgumentError for the options that the reader or writer of the encode stream would raise for once the
    # text is read or written: an encoding that Ruby does not know, or that is neither a String nor an Encoding, one
    # whose text Ruby cannot convert as the encode stream converts it, see .check_convertible, a `replace` that is not
    # a String, or a cleaner that is neither the name of a built-in rule nor a Proc, see `IOStreams::Encode::Cleaner`.
    # So that they raise when they are set, see `IOStreams::Builder#encoding`, and before a writer opens its output, see
    # `IOStreams::StreamFormat#check_stream`, which would replace an existing file, rather than once the data is read or
    # written.
    def self.check(encoding: default_encoding, cleaner: nil, replace: nil)
      unless encoding.nil? || encoding.is_a?(String) || encoding.is_a?(Encoding)
        raise(ArgumentError, "Invalid encoding #{encoding.inspect}: supply the name of an encoding, such as " \
                             "\"UTF-8\" or \"Windows-1252:UTF-8\", or an Encoding")
      end
      unless replace.nil? || replace.is_a?(String)
        raise(ArgumentError, "Invalid replace #{replace.inspect}: supply the String that replaces each invalid character")
      end

      external, internal = external_and_internal(encoding)
      external           = Encoding.find(external) if external.is_a?(String)
      check_convertible(encoding, external, internal) if external
      Cleaner.new(cleaner, replace: replace) unless cleaner.nil?
      nil
    end

    # Raises ArgumentError for an encoding whose text the encode stream converts, but that Ruby has no converter for,
    # so that it raises when it is set, rather than Encoding::ConverterNotFoundError once the text is read or written.
    # Reading converts the text from the external encoding to the internal one, such as from Windows-1258 for
    # "Windows-1258:UTF-8". The text of an external encoding that is not ASCII compatible, such as "UTF-7", is
    # converted from UTF-8 too: the line endings that the line reader looks for, and the text that is written.
    #
    # An ASCII compatible encoding needs no converter for its line endings, nor for ASCII text, so the text of one that
    # Ruby cannot convert, such as "Windows-1258", is still read and written as it is, as it was before this check.
    #
    # Parameters
    #   option: [String|Encoding]
    #     The `encoding` option, for the message, such as "Windows-1258:UTF-8".
    #
    #   external: [Encoding]
    #     The encoding of the data, see .external_and_internal.
    #
    #   internal: [Encoding|nil]
    #     The encoding that reading converts the text to, or nil.
    def self.check_convertible(option, external, internal)
      if internal && internal != external && !converter?(external, internal)
        raise(ArgumentError, "Invalid encoding #{option.inspect}: Ruby cannot convert text from #{external} to #{internal}")
      end
      return if external.ascii_compatible? || converter?(Encoding::UTF_8, external)

      raise(ArgumentError, "Invalid encoding #{option.inspect}: Ruby cannot convert text to or from #{external}")
    end
    private_class_method :check_convertible

    # Returns [true|false] whether Ruby has a converter of text from the source encoding to the destination encoding.
    def self.converter?(source, destination)
      Encoding::Converter.new(source, destination)
      true
    rescue Encoding::ConverterNotFoundError
      false
    end
    private_class_method :converter?

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
