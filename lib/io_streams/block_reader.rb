# frozen_string_literal: true

module IOStreams
  # Reads the stream of a gem's reader that decompresses or decrypts the data as it is read, such as
  # `Bzip2::FFI::Reader`, a block at a time, like an IO: `#read`, `#readpartial` and `#eof?`, see
  # `IOStreams::ChunkReader`. So that the stream that the reader of a format supplies to its block behaves the same way
  # whichever format the file name names, whatever the gem's reader does itself, such as answer `#eof?` with false once
  # all of the data has been read, or leave the data of an earlier read in the buffer supplied to `#read`.
  #
  # Holds one block of the data at a time.
  class BlockReader
    include ChunkReader

    # The number of bytes read from the stream at a time.
    BLOCK_SIZE = 65_536

    # Parameters
    #   stream [#read]
    #     Returns upto the requested number of bytes from `#read(length, buffer)`, or nil at the end of the data.
    def initialize(stream)
      @stream = stream
      @block  = String.new(capacity: BLOCK_SIZE, encoding: Encoding::BINARY)
    end

    # Returns [true|false] whether the stream has been closed, such as by the reader once its block returns, after
    # which every read raises IOError.
    def closed?
      @stream.respond_to?(:closed?) && @stream.closed?
    end

    private

    # Returns [String] the next block of the data, or nil at its end, see `IOStreams::ChunkReader`.
    #
    # The same buffer is read into each time, since the block before it has always been read by then.
    def next_chunk
      @stream.read(BLOCK_SIZE, @block)
    end
  end
end
