# frozen_string_literal: true

require "delegate"
require "stringio"

module IOStreams
  # The methods of an IO that write, `#write`, `#<<`, `#print`, `#puts` and `#printf`, for the stream that the writer of
  # a format supplies to its block, so that the code that writes the data works whichever format the file name names,
  # since a path is configuration, whose file name can change from `.gz` to `.bz2`.
  #
  # The class that includes it supplies `#write_data`, which writes [String] data, and returns [Integer] the number of
  # bytes written. The writer of a gem that lacks these methods is wrapped in an Adapter.
  module Writable
    # Like `IO#write`: writes each object as a String, and returns [Integer] the number of bytes written.
    def write(*objects)
      objects.sum { |object| write_data(object.to_s) }
    end

    # Returns self, so that writes can be chained, such as `io << "a" << "b"`.
    def <<(object)
      write(object)
      self
    end

    # Like `IO#print`: writes each object. Returns nil.
    def print(*objects)
      write(*objects)
      nil
    end

    # Like `IO#puts`: writes each object, and each element of an Array, followed by a newline unless it already ends
    # with one, or a newline without any objects. Returns nil.
    #
    # Each one is written with #write, as `IO#puts` writes it, so that its text keeps its encoding, which a writer of
    # text, such as the encode stream, converts, and a writer of bytes, such as gzip, writes as it is.
    def puts(*objects)
      objects.empty? ? write("\n") : objects.each { |object| puts_object(object, []) }
      nil
    end

    # Like `IO#printf`: writes the objects formatted with the format string. Returns nil.
    def printf(format, *objects)
      write(::Kernel.format(format, *objects))
      nil
    end

    private

    # Writes the object as `IO#puts` does: each element of an Array, and "[...]" for an Array within itself, otherwise
    # its text, followed by a newline unless it already ends with one.
    #
    # Parameters
    #   arrays: [Array<Array>]
    #     The Arrays that the object is within.
    def puts_object(object, arrays)
      array = ::Array.try_convert(object)
      return puts_line(object.to_s) if array.nil?
      return puts_line("[...]") if arrays.any? { |outer| outer.equal?(array) }

      array.each { |item| puts_object(item, [*arrays, array]) }
    end

    # Writes the text, followed by a newline unless it already ends with one.
    def puts_line(text)
      write(text)
      write("\n") unless newline_at_end?(text)
    end

    # Returns [true|false] whether the text ends with a newline in its own encoding, which can be one that is not ASCII
    # compatible, such as UTF-16LE.
    def newline_at_end?(text)
      return false if text.empty?
      return text.end_with?("\n") if text.encoding.ascii_compatible?

      text.end_with?("\n".encode(text.encoding))
    rescue EncodingError
      false
    end

    # The writer of a gem that responds to `#write`, such as `Bzip2::FFI::Writer`, with the methods of Writable that it
    # lacks. Every other method is the writer's own, such as `#flush`.
    class Adapter < SimpleDelegator
      include Writable

      private

      # Writes nothing for empty data, which some gems reject, such as `SymmetricEncryption::Writer` on JRuby, whose
      # OpenSSL raises `ArgumentError: data must not be empty` from `Cipher#update`, while an IO writes nothing.
      def write_data(data)
        return 0 if data.empty?

        __getobj__.write(data)
        data.bytesize
      end
    end
  end
end
