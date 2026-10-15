# frozen_string_literal: true

module IOStreams
  # Reads the stream of a gem's reader that decompresses or decrypts the data as it is read, such as
  # `Bzip2::FFI::Reader`, a block at a time, like an IO: `#read`, `#readpartial` and `#eof?`, see
  # `IOStreams::ChunkReader`. So that the stream that the reader of a format supplies to its block behaves the same way
  # whichever format the file name names, whatever the gem's reader does itself, such as answer `#eof?` with false once
  # all of the data has been read, or leave the data of an earlier read in the buffer supplied to `#read`. Likewise an
  # exception that the gem's reader raises for data that it cannot read is tagged with the kind of failure, such as
  # `IOStreams::Errors::Corrupt`, so that it is rescued the same way whichever format the file name names.
  #
  # Holds one block of the data at a time.
  class BlockReader
    include ChunkReader

    # The number of bytes read from the stream at a time.
    BLOCK_SIZE = 65_536

    # Parameters
    #   stream [#read]
    #     Returns upto the requested number of bytes from `#read(length, buffer)`, or nil at the end of the data.
    #
    #   failures: [Class]
    #     The reader of the format, which tags an exception that the stream raises with the kind of failure that it
    #     means, such as `IOStreams::Errors::Corrupt` for data that is not valid, see `IOStreams::Reader.tag_failure`.
    #     Default: `IOStreams::Reader`, which tags none.
    def initialize(stream, failures: Reader)
      @stream   = stream
      @failures = failures
      @block    = String.new(capacity: BLOCK_SIZE, encoding: Encoding::BINARY)
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
      @failures.tag_failure { @stream.read(BLOCK_SIZE, @block) }
    end
  end
end
