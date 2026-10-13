# frozen_string_literal: true

require_relative "../test_helper"

module Paths
  class HTTPBodyReaderTest < Minitest::Test
    describe IOStreams::Paths::HTTP::BodyReader do
      let(:chunks) { %w[0123 4567 89ab cdef ghij] }
      let(:events) { [] }

      # Returns a request that supplies each of the chunks to the block, recording when it starts and finishes.
      def request(chunks = self.chunks)
        lambda do |&block|
          events << :started
          chunks.each { |chunk| block.call(chunk.dup) }
          events << :finished
        ensure
          events << :ended
        end
      end

      def reader(chunks = self.chunks)
        IOStreams::Paths::HTTP::BodyReader.new(request(chunks))
      end

      describe "#read" do
        it "reads the whole body" do
          assert_equal "0123456789abcdefghij", reader.read
        end

        it "reads lengths that span chunks" do
          input = reader

          assert_equal "012345", input.read(6)
          assert_equal "6789abcdef", input.read(10)
          assert_equal "ghij", input.read(6)
          assert_nil input.read(1)
        end

        it "reads the rest of the body after a length" do
          input = reader
          input.read(5)

          assert_equal "56789abcdefghij", input.read
          assert_equal "", input.read
        end

        it "returns binary strings" do
          assert_equal Encoding::BINARY, reader(["é"]).read(2).encoding
        end

        it "replaces the contents of outbuf" do
          input  = reader
          outbuf = +"previous"

          assert_same outbuf, input.read(3, outbuf)
          assert_equal "012", outbuf
        end

        it "empties outbuf at the end of the body" do
          input  = reader(["01"])
          outbuf = +"previous"
          input.read

          assert_nil input.read(3, outbuf)
          assert_equal "", outbuf
        end

        it "returns an empty string for a length of zero" do
          assert_equal "", reader.read(0)
        end

        it "skips empty chunks" do
          assert_equal "0123", reader(["", "01", "", "23", ""]).read
        end

        it "reads an empty body" do
          input = reader([])

          assert_nil input.read(1)
          assert_equal "", input.read
        end

        it "raises ArgumentError for a negative length, rather than ending the body" do
          error = assert_raises(ArgumentError) { reader.read(-1) }
          assert_equal "negative length -1 given", error.message
        end
      end

      describe "#readpartial" do
        it "reads within the current chunk" do
          input = reader

          assert_equal "012", input.readpartial(3)
          assert_equal "3", input.readpartial(3)
          assert_equal "456", input.readpartial(3)
        end

        it "raises EOFError at the end of the body" do
          input = reader(["01"])
          input.readpartial(10)

          assert_raises(EOFError) { input.readpartial(10) }
        end

        it "replaces the contents of outbuf" do
          outbuf = +"previous"

          assert_same outbuf, reader.readpartial(2, outbuf)
          assert_equal "01", outbuf
        end

        it "raises ArgumentError for a negative length" do
          assert_raises(ArgumentError) { reader.readpartial(-1) }
        end
      end

      describe "#eof?" do
        it "is false until the whole body has been read" do
          input = reader(%w[01 23])

          refute_predicate input, :eof?
          input.read(4)

          assert_predicate input, :eof?
        end

        it "is true for an empty body" do
          assert_predicate reader([]), :eof?
        end
      end

      describe "the request" do
        it "is made when the reader is created, before the body is read" do
          reader

          assert_equal [:started], events
        end

        it "receives each chunk as the body is read, rather than all of them first" do
          received = []
          input    = IOStreams::Paths::HTTP::BodyReader.new(
            lambda do |&block|
              chunks.each do |chunk|
                received << chunk
                block.call(chunk)
              end
            end
          )

          assert_equal %w[0123], received
          input.read(5)

          assert_equal %w[0123 4567], received
        end

        it "raises its failure when the reader is created" do
          assert_raises(Errno::ECONNREFUSED) { IOStreams::Paths::HTTP::BodyReader.new(->(&_block) { raise(Errno::ECONNREFUSED) }) }
        end

        it "raises its failure to the caller, and again on every later read, rather than ending the body" do
          input = IOStreams::Paths::HTTP::BodyReader.new(
            lambda do |&block|
              block.call("01")
              raise(Errno::ECONNRESET)
            end
          )

          assert_equal "01", input.read(2)
          failure = assert_raises(Errno::ECONNRESET) { input.read(1) }
          assert_same failure, assert_raises(Errno::ECONNRESET) { input.read(1) }
          assert_same failure, assert_raises(Errno::ECONNRESET) { input.read }
          assert_same failure, assert_raises(Errno::ECONNRESET) { input.readpartial(1) }
          assert_same failure, assert_raises(Errno::ECONNRESET) { input.eof? }
        end

        it "starts with the fiber-local variables of the caller, such as the tags of a logger" do
          Thread.current[:iostreams_test_tags] = %w[job]
          tags = nil
          IOStreams::Paths::HTTP::BodyReader.new(->(&_block) { tags = Thread.current[:iostreams_test_tags] })

          assert_equal %w[job], tags
        ensure
          Thread.current[:iostreams_test_tags] = nil
        end

        it "runs in a Fiber that is not blocking, so that a Fiber scheduler can run its other Fibers while it waits" do
          blocking = nil
          IOStreams::Paths::HTTP::BodyReader.new(->(&_block) { blocking = Fiber.current.blocking? })

          refute blocking
        end
      end

      describe "#close" do
        it "stops the request when the body has not all been read" do
          input = reader
          input.read(1)
          input.close

          assert_equal %i[started ended], events
          assert_predicate input, :closed?
        end

        it "does nothing more once the body has all been read" do
          input = reader
          input.read
          input.close

          assert_equal %i[started finished ended], events
        end

        it "does not raise a failure of the request as it stops" do
          input = IOStreams::Paths::HTTP::BodyReader.new(
            lambda do |&block|
              block.call("0123")
            rescue StandardError
              # Like Net::HTTP reading the end of its chunk from a connection that has closed.
              raise(EOFError)
            end
          )

          assert_nil input.close
        end

        it "raises IOError when reading afterwards, even with bytes left in the current chunk" do
          input = reader
          input.read(1)
          input.close

          assert_raises(IOError) { input.read(1) }
          assert_raises(IOError) { input.readpartial(1) }
          assert_raises(IOError) { input.eof? }
        end
      end

      describe ".open" do
        it "returns the result of the block, and closes the reader once it returns" do
          result = IOStreams::Paths::HTTP::BodyReader.open(request) do |input|
            input.read(1)
            :result
          end

          assert_equal :result, result
          assert_equal %i[started ended], events
        end

        it "closes the reader when the block raises" do
          assert_raises(ArgumentError) { IOStreams::Paths::HTTP::BodyReader.open(request) { |_input| raise(ArgumentError) } }
          assert_equal %i[started ended], events
        end
      end
    end
  end
end
