module IOStreams
  module Paths
    class HTTP < IOStreams::Path
      # Reads the body of a response one chunk at a time as the caller reads it, so that the body is not downloaded
      # into a temp file first, and only one chunk is held in memory.
      #
      # Net::HTTP pushes the body that it downloads to a block, so the request runs in a Fiber of its own, which is
      # resumed whenever the caller needs the next chunk. The request, and any failure of it, stay in that Fiber, and
      # the caller's code stays in the caller's Fiber, so a failure of the caller is never mistaken for a failure of
      # the request.
      #
      # Like a Fiber, it can only be read by the thread that created it.
      #
      # Used internally by the HTTP path, which makes the request, so that it supplies its url and options, follows
      # redirects, and checks the size of the body.
      class BodyReader
        # Raised within the request to stop it, when the body is closed before it has all been read.
        class Stop < StandardError
        end
        private_constant :Stop

        # Parameters:
        #   request: [Proc]
        #     Makes the request, calling the block that it is supplied with each chunk of the body.
        def initialize(request)
          @chunk   = "".b
          @offset  = 0
          @closed  = false
          @started = false
          # Blocking, so that a Fiber scheduler, such as Async, does not switch to another Fiber part way through
          # reading a chunk, which would resume the request from a Fiber other than the caller's.
          @fiber = Fiber.new(blocking: true) do
            request.call { |chunk| Fiber.yield(chunk) }
            nil
          rescue Stop
            nil
          end
        end

        # Returns [String] upto `length` bytes, or nil at the end of the body, or with no length, the rest of the body,
        # like `IO#read`. The bytes replace the contents of `outbuf` when it is supplied.
        def read(length = nil, outbuf = nil)
          data = length.nil? ? read_rest : read_upto(length)
          return data unless outbuf

          outbuf.replace(data.to_s)
          outbuf unless data.nil?
        end

        # Returns [String] upto `maxlen` bytes that have already been received, reading the next chunk only when they
        # have all been read, like `IO#readpartial`. Raises EOFError at the end of the body.
        def readpartial(maxlen, outbuf = nil)
          raise(EOFError, "end of file reached") if maxlen.positive? && eof?

          data = @chunk.byteslice(@offset, maxlen)
          @offset += data.bytesize
          outbuf ? outbuf.replace(data) : data
        end

        # Returns [true|false] whether the whole body has been read, reading the next chunk to find out, like
        # `IO#eof?`.
        def eof?
          @offset >= @chunk.bytesize && !next_chunk
        end

        alias eof eof?

        # Stops the request when the body has not all been read, which closes its connection. Returns nil.
        def close
          @closed = true
          @chunk  = "".b
          @offset = 0
          @fiber.raise(Stop) if @fiber.alive? && started?
          nil
        end

        def closed?
          @closed
        end

        private

        def read_upto(length)
          return "".b if length.zero?

          data = nil
          while length.positive?
            break if @offset >= @chunk.bytesize && !next_chunk

            part = @chunk.byteslice(@offset, length)
            @offset += part.bytesize
            length  -= part.bytesize
            data ? data << part : data = part
          end
          data
        end

        def read_rest
          data = "".b
          while @offset < @chunk.bytesize || next_chunk
            data << @chunk.byteslice(@offset..)
            @offset = @chunk.bytesize
          end
          data
        end

        # Resumes the request until it supplies the next chunk that is not empty, which replaces the last one.
        # Returns [String] the chunk, or nil at the end of the body.
        def next_chunk
          raise(IOError, "closed stream") if @closed

          while @fiber.alive?
            @started = true
            chunk    = @fiber.resume
            next if chunk.nil? || chunk.empty?

            @chunk  = chunk.b
            @offset = 0
            return @chunk
          end
          nil
        end

        def started?
          @started
        end
      end
    end
  end
end
