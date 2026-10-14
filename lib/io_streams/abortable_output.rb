# frozen_string_literal: true

module IOStreams
  # The output stream of a compressor that a writer aborts when its block fails, such as `Zlib::GzipWriter`: passes
  # what the compressor writes on to the output stream until #discard, and then discards it.
  #
  # So that the writer can still end the compressor, which frees its memory, without writing the end of the data,
  # such as the trailer of a gzip file, which would make what was written look like a complete file.
  #
  # Every other request is passed on to the output stream, such as `#close` for a compressor that closes its output
  # when it is asked to, as bzip2 does with `autoclose: true`.
  class AbortableOutput
    def initialize(output_stream)
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
  end
end
