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
      # The request starts with the caller's fiber-local variables, such as the tags of a logger, as it would in the
      # caller's Fiber. Under a Fiber scheduler, such as Async, the request waits for the network in the scheduler, so
      # that the scheduler's other Fibers run meanwhile.
      #
      # Like a Fiber, it can only be read by the thread that created it.
      #
      # Used internally by the HTTP path, which makes the request, so that it supplies its url and options, follows
      # redirects, and checks the body.
      class BodyReader
        include ChunkReader

        # Raised within the request to stop it, when the body is closed before it has all been read.
        class Stop < StandardError
        end
        private_constant :Stop

        # Makes the request, and returns the result of the block, which is called with the reader of its body.
        #
        # The reader is closed once the block returns, which stops the request when the body has not all been read.
        def self.open(request)
          reader = new(request)
          yield(reader)
        ensure
          reader&.close
        end

        # Makes the request, and waits for the first chunk of its body, so that a failure of the request, such as a
        # missing file, raises before the body is read.
        #
        # Parameters:
        #   request: [Proc]
        #     Makes the request, calling the block that it is supplied with each chunk of the body.
        def initialize(request)
          @closed  = false
          @failure = nil
          locals   = fiber_locals
          @fiber   = Fiber.new do
            locals.each { |key, value| Thread.current[key] = value }
            request.call { |chunk| Fiber.yield(chunk) }
            nil
          rescue Stop
            nil
          end
          eof?
        end

        # Stops the request when the body has not all been read, which closes its connection. Returns nil.
        def close
          @closed = true
          stop if @fiber.alive?
          nil
        end

        def closed?
          @closed
        end

        private

        # Resumes the request until it supplies the next chunk. Returns [String] the chunk, or nil at the end of the
        # body, see `ChunkReader`.
        #
        # Once the request has failed, every later read raises its failure again, rather than finding the end of the
        # body.
        def next_chunk
          raise(@failure) if @failure

          @fiber.resume if @fiber.alive?
        rescue Exception => e # rubocop:disable Lint/RescueException
          @failure = e
          raise
        end

        # Stops the request, ignoring any failure of it as it stops, since the rest of the body is not needed. For
        # example, Net::HTTP reads the end of the chunk that it is in, which fails when the connection has closed, and
        # would otherwise replace an exception that the block raised.
        def stop
          @fiber.raise(Stop)
        rescue StandardError
          nil
        end

        # Returns [Hash] the fiber-local variables of the caller's Fiber.
        def fiber_locals
          thread = Thread.current
          thread.keys.to_h { |key| [key, thread[key]] }
        end
      end
    end
  end
end
