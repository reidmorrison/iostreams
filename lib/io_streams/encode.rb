# frozen_string_literal: true

module IOStreams
  # Converts the text that the application reads or writes to an encoding, and optionally cleanses it, see
  # `IOStreams::Encode::Reader` and `IOStreams::Encode::Writer`.
  module Encode
    autoload :Reader, "io_streams/encode/reader"
    autoload :Writer, "io_streams/encode/writer"

    # What the application uses in place of the #encoding and #cleaner of the reader and writer of the encode stream,
    # which v3.0 removes: the settings of the path, which return what was set in both versions, see
    # `IOStreams::Reader.v3_stream_advice`.
    V3_STREAM_ADVICE = {
      encoding: "use the #encoding of the path instead, which returns the encoding that was set, such as \"UTF-8\", or " \
                "Encoding.find(path.encoding) for its Encoding",
      cleaner:  "use path.setting(:encode)[:cleaner] instead, which returns the cleaner that was set, such as :printable"
    }.freeze
    private_constant :V3_STREAM_ADVICE

    # Returns [Array<Symbol>] the names of the options of the encode stream, which its reader and writer both take.
    def self.option_names
      Reader.option_names | Writer.option_names
    end

    # Raises ArgumentError for the options of the encode stream that its reader or writer would raise for once the text
    # is read or written: an option that it does not take, an encoding that Ruby does not know, or that is neither a
    # String nor an Encoding, one that Ruby cannot convert text to, see .check_convertible, a `replace` that is not a
    # String, or a cleaner that is not the name of a built-in rule. Also for a cleaner that is neither a Symbol nor a
    # Proc, which the reader and writer ignore, so that the text would not be cleansed.
    #
    # So that `IOStreams::Builder#encoding` raises when the options are set, rather than once a writer has replaced the
    # file that it writes.
    def self.check(**options)
      unknown = options.keys - option_names
      if unknown.any?
        raise(ArgumentError, "Unknown encoding #{unknown.size == 1 ? 'option' : 'options'} #{list(unknown)}. " \
                             "Valid options: #{list(option_names)}.")
      end

      check_encoding(options[:encoding]) if options.key?(:encoding)
      check_replace(options[:replace])
      check_cleaner(options[:cleaner])
      nil
    end

    def self.check_encoding(encoding)
      unless encoding.is_a?(String) || encoding.is_a?(Encoding)
        raise(ArgumentError, "Invalid encoding #{encoding.inspect}: supply the name of an encoding, such as " \
                             "\"UTF-8\" or \"Windows-1252\", or an Encoding")
      end

      check_convertible(encoding, encoding.is_a?(String) ? Encoding.find(encoding) : encoding)
    end
    private_class_method :check_encoding

    # Raises ArgumentError for an encoding that Ruby has no converter for, such as "UTF-7", so that it raises when it is
    # set, rather than Encoding::ConverterNotFoundError once the text is read or written. The text that is read and
    # written is converted to the encoding, such as from the UTF-8 that the application writes. An ASCII compatible
    # encoding needs no converter for ASCII text, so the text of one that Ruby cannot convert, such as "Windows-1258",
    # is still read and written as it is.
    def self.check_convertible(option, encoding)
      return if encoding.ascii_compatible? || converter?(Encoding::UTF_8, encoding)

      raise(ArgumentError, "Invalid encoding #{option.inspect}: Ruby cannot convert text to or from #{encoding}")
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

    def self.check_replace(replace)
      return if replace.nil? || replace.is_a?(String)

      raise(ArgumentError, "Invalid replace #{replace.inspect}: supply the String that replaces each invalid character")
    end
    private_class_method :check_replace

    def self.check_cleaner(cleaner)
      unless cleaner.nil? || cleaner.is_a?(Symbol) || cleaner.is_a?(Proc)
        raise(ArgumentError,
              "Invalid cleaner #{cleaner.inspect}: supply the name of a built-in rule, such as :printable, or a Proc")
      end

      Reader.extract_cleaner(cleaner)
    end
    private_class_method :check_cleaner

    def self.list(names)
      names.map(&:inspect).join(", ")
    end
    private_class_method :list
  end
end
