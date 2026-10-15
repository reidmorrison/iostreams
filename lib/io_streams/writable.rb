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
    # with one. Returns nil.
    def puts(*objects)
      lines = ::StringIO.new(+"")
      lines.puts(*objects)
      write(lines.string)
      nil
    end

    # Like `IO#printf`: writes the objects formatted with the format string. Returns nil.
    def printf(format, *objects)
      write(::Kernel.format(format, *objects))
      nil
    end

    # The writer of a gem that responds to `#write`, such as `Bzip2::FFI::Writer`, with the methods of Writable that it
    # lacks. Every other method is the writer's own, such as `#flush`.
    class Adapter < SimpleDelegator
      include Writable

      private

      def write_data(data)
        __getobj__.write(data)
        data.bytesize
      end
    end
  end
end
