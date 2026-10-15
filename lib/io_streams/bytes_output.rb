# frozen_string_literal: true

require "delegate"

module IOStreams
  # Writes what the streams write, the bytes of compressed or encrypted data, or of text in the encoding of the encode
  # stream, as it is, to an IO supplied to `IOStreams.stream` that converts the text written to it.
  #
  # Ruby converts each String written to an IO that has an external encoding, from the encoding of the String to that
  # one. A `StringIO` has the encoding of its String, an IO opened with an encoding, such as
  # `File.open(name, "w:UTF-8")`, or after `#set_encoding`, has that one, and so does every IO opened in text mode once
  # `Encoding.default_internal` is set, as Rails sets it. So text that the encode stream writes in Windows-1252 would be
  # converted back to UTF-8, and the bytes of a gzip stream would raise `Encoding::UndefinedConversionError`. Ruby
  # leaves a String in the external encoding of the IO as it is, so each String is written tagged with it.
  #
  # An IO, rather than a `StringIO`, whose external encoding is not ASCII compatible, such as UTF-16LE, still converts
  # a String in it to UTF-8 and back, so it raises `Encoding::InvalidByteSequenceError` for bytes that are not valid in
  # that encoding, rather than changing them.
  #
  # Every other request is passed on to the IO, such as `#flush`.
  class BytesOutput < SimpleDelegator
    include Writable

    # Returns the supplied IO when it writes Strings as they are, without an external encoding, or with a binary one,
    # otherwise the IO in a BytesOutput.
    def self.for(io)
      encoding = io.external_encoding if io.respond_to?(:external_encoding)
      encoding.nil? || encoding == Encoding::BINARY ? io : new(io, encoding)
    end

    def initialize(io, encoding)
      super(io)
      @encoding = encoding
    end

    private

    # Writes the data to the IO tagged with the IO's external encoding, so that converting it to that encoding leaves it
    # as it is. Returns [Integer] the number of bytes written.
    def write_data(data)
      __getobj__.write(data.encoding == @encoding ? data : data.dup.force_encoding(@encoding))
    end
  end
end
