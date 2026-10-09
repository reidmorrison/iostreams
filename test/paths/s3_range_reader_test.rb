require_relative "../test_helper"
require_relative "../s3_stub"

module Paths
  class S3RangeReaderTest < Minitest::Test
    Response = Struct.new(:body, :content_range, :etag, :version_id, keyword_init: true)

    describe IOStreams::Paths::S3::RangeReader do
      before do
        IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
      end

      let(:data) { "0123456789abcdefghij" }
      let(:requests) { [] }

      # Returns the requested range of the data, as S3 does, recording the parameters of each request.
      def object(data, etag: "\"etag\"", version_id: nil)
        lambda do |**params|
          requests << params
          return Response.new(body: StringIO.new(data.dup), etag: etag, version_id: version_id) unless params[:range]

          first, last = params[:range].delete_prefix("bytes=").split("-").map(&:to_i)
          raise Aws::S3::Errors::InvalidRange.new(nil, "range") if first >= data.bytesize

          part = data.byteslice(first..last)
          Response.new(body:          StringIO.new(part),
                       content_range: "bytes #{first}-#{first + part.bytesize - 1}/#{data.bytesize}",
                       etag:          etag,
                       version_id:    version_id)
        end
      end

      def reader(data = self.data, range_size: 8, **)
        IOStreams::Paths::S3::RangeReader.new(object(data, **), range_size: range_size)
      end

      describe ".supports?" do
        it "supports options that do not choose the bytes to read" do
          assert IOStreams::Paths::S3::RangeReader.supports?(%i[request_payer version_id])
        end

        it "does not support the range or part_number options" do
          refute IOStreams::Paths::S3::RangeReader.supports?(%i[range])
          refute IOStreams::Paths::S3::RangeReader.supports?(%i[part_number])
        end
      end

      describe "#read" do
        it "reads the whole object, one range at a time" do
          assert_equal data, reader.read
          assert_equal(["bytes=0-7", "bytes=8-15", "bytes=16-23"], requests.map { |params| params[:range] })
        end

        it "reads a length across ranges, and nil at the end, like IO#read" do
          io = reader

          assert_equal "0123456789ab", io.read(12)
          assert_equal "cdefghij", io.read(12)
          assert_nil io.read(12)
          assert_equal "", io.read
          assert_equal "", io.read(0)
        end

        it "replaces the contents of the output buffer" do
          io     = reader
          buffer = +"old"

          assert_same buffer, io.read(4, buffer)
          assert_equal "0123", buffer
          io.read

          assert_nil io.read(4, buffer)
          assert_equal "", buffer
        end

        it "returns binary strings" do
          assert_equal Encoding::BINARY, reader("é".encode("UTF-8")).read(1).encoding
        end

        it "reads an empty object, of which S3 cannot return a range" do
          io = reader("")

          assert_nil io.read(4)
          assert_predicate io, :eof?
          assert_equal [{range: "bytes=0-7"}, {}], requests
        end

        it "reads the whole object from a response without a range" do
          io = IOStreams::Paths::S3::RangeReader.new(->(**) { Response.new(body: StringIO.new(data)) }, range_size: 8)

          assert_equal data, io.read
        end
      end

      describe "a range without any data" do
        it "raises before the end of the object, rather than ending it early" do
          responses = [Response.new(body: StringIO.new("0123"), content_range: "bytes 0-3/20"), Response.new(body: StringIO.new(""))]
          io        = IOStreams::Paths::S3::RangeReader.new(->(**) { responses.shift }, range_size: 4)

          assert_equal "0123", io.read(4)
          assert_raises(IOStreams::Errors::CommunicationsFailure) { io.read(4) }
        end
      end

      describe "#readpartial" do
        it "returns the bytes already requested, and raises EOFError at the end" do
          io = reader

          assert_equal "0123", io.readpartial(4)
          assert_equal "4567", io.readpartial(100)
          assert_equal "89abcdef", io.readpartial(100)
          assert_equal "ghij", io.readpartial(100)
          assert_raises(EOFError) { io.readpartial(100) }
        end

        it "can be copied by IO.copy_stream" do
          output = StringIO.new

          IO.copy_stream(reader, output)

          assert_equal data, output.string
        end
      end

      describe "#eof?" do
        it "is true once the last byte has been read, without another request" do
          io = reader

          refute_predicate io, :eof?
          io.read(20)

          assert_predicate io, :eof?
          assert_equal 3, requests.size
        end
      end

      describe "the same object" do
        it "reads every range after the first from the object with the ETag of the first" do
          reader.read

          assert_equal([nil, "\"etag\"", "\"etag\""], requests.map { |params| params[:if_match] })
        end

        it "reads every range after the first from the version of the first" do
          reader(version_id: "v1").read

          assert_equal([nil, "v1", "v1"], requests.map { |params| params[:version_id] })
          assert(requests.none? { |params| params.key?(:if_match) })
        end
      end

      describe "with an S3 path" do
        before do
          S3Stub.install
        end

        after do
          S3Stub.uninstall
        end

        it "reads an object larger than a range" do
          data = Random.new(42).bytes(IOStreams::Paths::S3::RangeReader::RANGE_SIZE + 10)
          path = IOStreams.path("s3://bucket/large.bin")
          path.write(data)
          path.client.api_requests.clear

          # Compares digests, so that data that differs is not displayed.
          assert_equal Digest::SHA256.hexdigest(data), Digest::SHA256.hexdigest(path.read)
          assert_equal(%i[get_object get_object], path.client.api_requests.map { |request| request[:operation_name] })
        end

        it "reads a gzip file larger than a range" do
          # Hex digits that do not compress to less than a range.
          lines = Random.new(42).bytes(9_000_000).unpack1("H*").scan(/.{1,60}/)
          path  = IOStreams.path("s3://bucket/large.csv.gz")
          path.writer(:line) { |io| lines.each { |line| io << line } }
          count = 0
          path.each(:line) { |line| count += 1 if line == lines[count] }

          assert_operator path.size, :>, IOStreams::Paths::S3::RangeReader::RANGE_SIZE
          assert_equal lines.size, count
        end

        it "reads an empty object" do
          path = IOStreams.path("s3://bucket/empty.csv")
          path.write("")

          assert_equal "", path.read
        end

        it "raises when the object is replaced while it is read" do
          path = IOStreams.path("s3://bucket/a.bin")
          path.write("a" * (IOStreams::Paths::S3::RangeReader::RANGE_SIZE + 1))

          error = assert_raises(Aws::S3::Errors::PreconditionFailed) do
            path.reader do |io|
              io.read(10)
              IOStreams.path("s3://bucket/a.bin").write("replaced")
              io.read
            end
          end
          refute_kind_of IOStreams::Errors::StorageError, error
        end

        it "raises NotFound for an object that does not exist" do
          error = assert_raises(IOStreams::Errors::NotFound) { IOStreams.path("s3://bucket/missing.csv").read }

          assert_instance_of Aws::S3::Errors::NoSuchKey, error
        end
      end
    end
  end
end
