# frozen_string_literal: true

require "delegate"

module IOStreams
  # The methods of an IO that write, `#write`, `#<<`, `#print`, `#puts` and `#printf`, for the stream that the writer of
  # a format supplies to its block, so that the code that writes the data works whichever format the file name names,
  # since a path is configuration, whose file name can change from `.gz` to `.bz2`.
  #
  # The class that includes it supplies `#write_data`, which writes [String] data, and returns [Integer] the number of
  # bytes written. The writer of a gem that lacks these methods is wrapped in an Adapter.
  module Writable
    # The newline at the end of text in an encoding whose characters are each 2 or 4 bytes, UTF-16 and UTF-32, as
    # `IO#puts` finds it, big-endian for "UTF-16" and "UTF-32", as Ruby reads them, see #newline_at_end?.
    NEWLINES = {
      ::Encoding::UTF_16BE => "\x00\n", ::Encoding::UTF_16LE => "\n\x00", ::Encoding::UTF_16 => "\x00\n",
      ::Encoding::UTF_32BE => "\x00\x00\x00\n", ::Encoding::UTF_32LE => "\n\x00\x00\x00",
      ::Encoding::UTF_32 => "\x00\x00\x00\n"
    }.transform_values(&:b).freeze

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
    # The text of each one keeps its encoding, as `IO#puts` writes it, which a writer of text, such as the encode stream,
    # converts, and a writer of bytes, such as gzip, writes as it is. Lines whose encodings Ruby combines without
    # changing their text, such as those of an Array of UTF-8 Strings, are written together, see #puts_line.
    def puts(*objects)
      if objects.empty?
        write("\n")
      else
        lines = puts_lines(objects, nil, nil)
        write(lines) if lines
      end
      nil
    end

    # Like `IO#printf`: writes the objects formatted with the format string. Returns nil.
    def printf(format, *objects)
      write(::Kernel.format(format, *objects))
      nil
    end

    private

    # Returns [String|nil] the supplied lines, which are still to be written, with the lines of the objects, as
    # `IO#puts` writes them: each element of an Array, "[...]" for an Array within itself, otherwise the text of the
    # object, see #puts_text, each followed by a newline unless it already ends with one, see #puts_line.
    #
    # Parameters
    #   arrays: [Array<Array>|nil]
    #     The Arrays that the objects are within.
    def puts_lines(objects, arrays, lines)
      objects.each do |object|
        array = ::Array.try_convert(object) unless object.is_a?(::String)
        lines =
          if array.nil?
            puts_line(puts_text(object), lines)
          elsif arrays&.any? { |outer| outer.equal?(array) }
            puts_line("[...]", lines)
          else
            puts_lines(array, arrays ? [*arrays, array] : [array], lines)
          end
      end
      lines
    end

    # Returns [String] the text of the object as `IO#puts` writes it: a String itself, otherwise its #to_s, or the text
    # that `Object#to_s` returns, such as "#<Object:0x...>", when that is not a String.
    def puts_text(object)
      return object if object.is_a?(::String)

      text = object.to_s
      text.is_a?(::String) ? text : ::Kernel.instance_method(:to_s).bind_call(object)
    end

    # Returns [String|nil] the supplied lines with the line added, followed by a newline unless it ends with one, see
    # #newline_at_end?. Writes the lines first when the line cannot be combined with them, as Ruby combines Strings,
    # without changing its text, such as a line of Windows-1252 text that follows lines of UTF-8 text.
    #
    # A line of text that is not ASCII compatible, such as UTF-16LE, is written on its own, followed by a newline that
    # is written as a line on its own too, which a writer of text converts to the encoding that it writes, and a
    # writer of bytes writes as the byte that `IO#puts` writes.
    def puts_line(line, lines)
      if line.encoding.ascii_compatible?
        if lines.nil?
          # A String, rather than a copy of a String subclass, whose `#to_s` #write would write instead.
          lines = ::String.new(line)
        elsif lines.encoding == line.encoding || ::Encoding.compatible?(lines, line)
          lines << line
        else
          write(lines)
          lines = ::String.new(line)
        end
        # The last byte, see #newline_at_end?.
        return line.getbyte(-1) == 10 ? lines : lines << "\n"
      end

      write(lines) if lines
      write(line)
      write("\n") unless newline_at_end?(line)
      nil
    end

    # Returns [true|false] whether the text ends with a newline, as `IO#puts` finds it: its last character in UTF-16 or
    # UTF-32, see NEWLINES, otherwise its last byte, so that an empty line does not.
    def newline_at_end?(text)
      newline = NEWLINES[text.encoding]
      return text.getbyte(-1) == 10 unless newline

      text.bytesize >= newline.bytesize && text.byteslice(-newline.bytesize, newline.bytesize).b == newline
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
