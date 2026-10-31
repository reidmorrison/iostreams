# frozen_string_literal: true

require "delegate"

module IOStreams
  # The output stream of a compressor that a writer aborts when its block fails, such as `Zlib::GzipWriter`: passes
  # what the compressor writes on to the output stream until #discard, and then discards it.
  #
  # So that the writer can still end the compressor, which frees its memory, without writing the end of the data,
  # such as the trailer of a gzip file, which would make what was written look like a complete file.
  #
  # Each method of an IO that writes is its own, so that none of them writes once #discard is called, whichever one the
  # compressor writes with: those of `IOStreams::Writable`, `#write`, `#<<`, `#print`, `#puts` and `#printf`, and
  # `#putc`, `#syswrite`, `#write_nonblock` and `#pwrite`, which call the output stream's own until then. Every other
  # request is passed on to the output stream, apart from #binmode, so that the compressor sees what the output stream
  # can do, such as `#close` for a compressor that closes its output when it is asked to, as bzip2 does with
  # `autoclose: true`, and `#path`, which `Zlib::GzipWriter` answers only when its output stream does.
  class AbortableOutput < SimpleDelegator
    include Writable

    def initialize(output_stream)
      super
      @discard = false
    end

    # Discards everything written from now on.
    def discard
      @discard = true
    end

    # Like the output stream's own `#putc`, until #discard. Returns the object.
    def putc(object)
      __getobj__.putc(object) unless @discard
      object
    end

    # Like the output stream's own `#syswrite`, until #discard. Returns [Integer] the number of bytes written, or
    # discarded.
    def syswrite(data)
      @discard ? data.to_s.bytesize : __getobj__.syswrite(data)
    end

    # Like the output stream's own `#write_nonblock`, until #discard. Returns [Integer] the number of bytes written, or
    # discarded.
    def write_nonblock(data, exception: true)
      @discard ? data.to_s.bytesize : __getobj__.write_nonblock(data, exception: exception)
    end

    # Like the output stream's own `#pwrite`, until #discard. Returns [Integer] the number of bytes written, or
    # discarded.
    def pwrite(data, offset)
      @discard ? data.to_s.bytesize : __getobj__.pwrite(data, offset)
    end

    def flush
      output = __getobj__
      output.flush if !@discard && output.respond_to?(:flush)
      self
    end

    def close
      output = __getobj__
      output.close if output.respond_to?(:close)
    end

    # Returns self, leaving the output stream in its mode, rather than switching it to binary mode for good, as a gem
    # such as bzip2-ffi asks, since the output stream belongs to the caller, as `IOStreams::Reader::Input` does for an
    # input stream. The builder hands a compressor an output stream that writes its bytes as they are, see
    # `IOStreams::BytesOutput`.
    def binmode
      self
    end

    private

    # Writes the data to the output stream, until #discard, see `IOStreams::Writable`. Returns [Integer] the number of
    # bytes written, or discarded.
    def write_data(data)
      __getobj__.write(data) unless @discard
      data.bytesize
    end
  end
end
