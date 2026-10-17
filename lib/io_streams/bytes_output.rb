# frozen_string_literal: true

require "delegate"

module IOStreams
  # Writes what the streams write, the bytes of compressed or encrypted data, or of text in the encoding set with
  # `#encoding`, as it is, to an IO supplied to `IOStreams.stream` that converts the text written to it, see
  # `IOStreams::Builder#writer`.
  #
  # Ruby converts each String written to an IO that has an external encoding, from the encoding of the String to that
  # one. A `StringIO` has the encoding of its String, an IO opened with an encoding, such as
  # `File.open(name, "w:UTF-8")`, or after `#set_encoding`, has that one, and so does every IO opened in text mode once
  # `Encoding.default_internal` is set, as Rails sets it. So text that the encode stream writes in Windows-1252 would be
  # converted back to UTF-8, and the bytes of a gzip stream would raise `Encoding::UndefinedConversionError`. Ruby
  # leaves a String in the external encoding of the IO as it is, so each String is written tagged with it.
  #
  # Ruby converts text to an external encoding that is not ASCII compatible, such as UTF-16LE, by way of UTF-8, which
  # only valid text survives, so such an IO is left to convert what is written to it, as it does without any streams,
  # see .for. An IO that changes the bytes written to it otherwise, such as a file opened with an encoding and
  # `newline: :crlf`, would corrupt binary data, such as the bytes of a gzip stream, so a write of binary data raises
  # once the IO changes it, see #write_data, while text gets the line endings that the IO writes, as without IOStreams.
  #
  # Every other request is passed on to the IO, such as `#flush`.
  class BytesOutput < SimpleDelegator
    include Writable

    # Returns the supplied IO when it writes Strings as they are, without an external encoding, or with a binary one,
    # or when its external encoding is not ASCII compatible, see above, otherwise the IO in a BytesOutput.
    def self.for(io)
      encoding = io.external_encoding if io.respond_to?(:external_encoding)
      return io if encoding.nil? || encoding == ::Encoding::BINARY || !encoding.ascii_compatible?

      new(io, encoding)
    end

    def initialize(io, encoding)
      super(io)
      @io       = io
      @encoding = encoding
    end

    # Writes each object, see #write_data. Returns [Integer] the number of bytes written. Writes one object, as a stream
    # writes each of its blocks, without the Array of the objects of `IOStreams::Writable#write`.
    def write(*objects)
      objects.size == 1 ? write_data(objects.first.to_s) : super
    end

    private

    # Writes the data to the IO tagged with the IO's external encoding, so that converting it to that encoding leaves it
    # as it is. Returns [Integer] the number of bytes of the data, since an IO-like object need not return the number
    # of bytes that it wrote.
    #
    # Raises ArgumentError when the IO wrote a different number of bytes for binary data, since it changed it.
    def write_data(data)
      binary  = data.encoding == ::Encoding::BINARY
      data    = data.dup.force_encoding(@encoding) unless data.encoding == @encoding
      size    = data.bytesize
      written = @io.write(data)
      return size if written == size || !binary || !written.is_a?(Integer)

      raise(ArgumentError, "The IO supplied to IOStreams.stream wrote #{written} bytes for the #{size} bytes written to " \
                           "it, so it changes them, such as with `newline: :crlf`: supply an IO in binary mode, such as " \
                           "`File.open(name, \"wb\")`")
    end
  end
end
