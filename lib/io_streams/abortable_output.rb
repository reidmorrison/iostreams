# frozen_string_literal: true

require "delegate"

module IOStreams
  # The output stream of a compressor that a writer aborts when its block fails, such as `Zlib::GzipWriter`: passes
  # what the compressor writes on to the output stream until #discard, and then discards it.
  #
  # So that the writer can still end the compressor, which frees its memory, without writing the end of the data,
  # such as the trailer of a gzip file, which would make what was written look like a complete file.
  #
  # Every other request is passed on to the output stream, apart from #binmode, so that the compressor sees what the
  # output stream can do, such as `#close` for a compressor that closes its output when it is asked to, as bzip2 does
  # with `autoclose: true`, and `#path`, which `Zlib::GzipWriter` answers only when its output stream does.
  class AbortableOutput < SimpleDelegator
    def initialize(output_stream)
      super
      @output_stream = output_stream
      @discard       = false
    end

    # Discards everything written from now on.
    def discard
      @discard = true
    end

    # Returns [Integer] the number of bytes written, or discarded.
    def write(data)
      return data.bytesize if @discard

      @output_stream.write(data)
    end

    def flush
      @output_stream.flush if !@discard && @output_stream.respond_to?(:flush)
      self
    end

    def close
      @output_stream.close if @output_stream.respond_to?(:close)
    end

    # Returns self, leaving the output stream in its mode, rather than switching it to binary mode for good, as a gem
    # such as bzip2-ffi asks, since the output stream belongs to the caller, as `IOStreams::Reader::Input` does for an
    # input stream. The builder hands a compressor an output stream that writes its bytes as they are, see
    # `IOStreams::BytesOutput`.
    def binmode
      self
    end
  end
end
