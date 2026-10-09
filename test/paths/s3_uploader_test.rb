require_relative "../test_helper"
require_relative "../s3_stub"

module Paths
  class S3UploaderTest < Minitest::Test
    PART_SIZE = IOStreams::Paths::S3::Uploader::PART_SIZE

    describe IOStreams::Paths::S3::Uploader do
      before do
        IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
        S3Stub.install
      end

      after do
        S3Stub.uninstall
      end

      let(:path) { IOStreams.path("s3://bucket/a.bin") }

      # Returns [Array<Symbol>] the operation of each request that the path made.
      def operations(path)
        path.client.api_requests.map { |request| request[:operation_name] }
      end

      # Returns [Array<Hash>] the parameters of each request that the path made for the operation.
      def params(path, operation)
        path.client.api_requests.select { |request| request[:operation_name] == operation }.map { |request| request[:params] }
      end

      # Compares digests, so that data that differs is not displayed.
      def assert_data(expected, actual)
        assert_equal Digest::SHA256.hexdigest(expected), Digest::SHA256.hexdigest(actual.b)
      end

      describe ".supports?" do
        it "supports options that every part, or the upload, can be supplied" do
          assert IOStreams::Paths::S3::Uploader.supports?(%i[acl request_payer checksum_algorithm if_none_match])
        end

        it "does not support options that describe the whole object" do
          %i[content_md5 content_length write_offset_bytes checksum_crc32 checksum_sha256].each do |name|
            refute IOStreams::Paths::S3::Uploader.supports?([name]), name
          end
        end
      end

      describe "upto one part" do
        it "stores the object with a single request" do
          path.write("data")

          assert_equal %i[put_object], operations(path)
          assert_equal "data", path.read
        end

        it "stores an empty object" do
          path.write("")

          assert_equal "", path.read
        end

        it "stores exactly one part with a single request" do
          data = Random.new(1).bytes(PART_SIZE)
          path.write(data)

          assert_equal %i[put_object], operations(path)
          assert_data data, path.read
        end
      end

      describe "more than one part" do
        let(:data) { Random.new(2).bytes((PART_SIZE * 2) + 10) }

        it "uploads the data in parts" do
          path.writer { |io| data.bytes.each_slice(1_000_000) { |slice| io.write(slice.pack("C*")) } }

          assert_equal %i[create_multipart_upload upload_part upload_part upload_part complete_multipart_upload], operations(path)
          # Parts are uploaded at the same time, so their requests can be in any order.
          parts = params(path, :upload_part).sort_by { |part| part[:part_number] }

          assert_equal([PART_SIZE, PART_SIZE, 10], parts.map { |part| part[:body].bytesize })
          assert_data data, path.read
        end

        it "uploads a single write larger than a part" do
          path.write(data)

          assert_equal([1, 2, 3], params(path, :upload_part).map { |part| part[:part_number] }.sort)
          assert_data data, path.read
        end

        it "completes the upload with every part in order" do
          path.write(data)

          parts = params(path, :complete_multipart_upload).first[:multipart_upload][:parts]

          assert_equal([1, 2, 3], parts.map { |part| part[:part_number] })
          assert(parts.all? { |part| part[:etag] })
        end

        it "supplies each request the options that it accepts" do
          path = IOStreams.path("s3://bucket/a.bin", acl: "bucket-owner-full-control", request_payer: "requester")
          path.write(data)

          assert_equal(["bucket-owner-full-control"], params(path, :create_multipart_upload).map { |request| request[:acl] })
          assert(params(path, :upload_part).none? { |request| request.key?(:acl) })
          assert_equal(%w[requester] * 3, params(path, :upload_part).map { |request| request[:request_payer] })
          assert_equal(["requester"], params(path, :complete_multipart_upload).map { |request| request[:request_payer] })
        end

        it "supplies the checksum of each part when the upload has a checksum algorithm" do
          path = IOStreams.path("s3://bucket/a.bin", checksum_algorithm: "CRC32")
          path.write(data)

          parts = params(path, :complete_multipart_upload).first[:multipart_upload][:parts]

          assert(parts.all? { |part| part.key?(:checksum_crc32) })
        end

        it "writes text in other encodings as its bytes" do
          text = "é" * (PART_SIZE / 2)
          path.writer { |io| io << text << text << "end" }

          assert_equal "#{text}#{text}end".b, path.read.b
        end

        it "writes a zip file" do
          zip_path = IOStreams.path("s3://bucket/a.csv.zip")
          zip_path.write(data.unpack1("H*"))

          assert_equal data.unpack1("H*"), zip_path.read
        end
      end

      describe "the size of a part" do
        let(:uploader) { IOStreams::Paths::S3::Uploader.new(->(*) {}) }

        def part_size(part_count)
          uploader.instance_variable_set(:@part_count, part_count)
          uploader.send(:part_size)
        end

        it "doubles after every PARTS_PER_SIZE parts" do
          assert_equal PART_SIZE, part_size(999)
          assert_equal PART_SIZE * 2, part_size(1_000)
          assert_equal PART_SIZE * 4, part_size(2_000)
        end

        it "fits the largest object that S3 accepts within its 10,000 parts, in parts that S3 accepts" do
          sizes = (0...10_000).map { |count| part_size(count) }

          assert_operator sizes.sum, :>=, 5 * (1024**4)
          assert_operator sizes.max, :<=, 5 * (1024**3)
        end
      end

      describe "failures" do
        let(:data) { Random.new(3).bytes((PART_SIZE * 2) + 10) }

        it "aborts the upload and raises the exception of the block unchanged" do
          error_class = Class.new(StandardError)

          assert_raises(error_class) do
            path.writer do |io|
              io.write(data)
              raise(error_class, "failed")
            end
          end
          assert_includes operations(path), :abort_multipart_upload
          assert_empty S3Stub.pending_uploads
          refute_predicate path, :exist?
        end

        it "aborts the upload for an exception that is not a StandardError" do
          error_class = Class.new(Exception) # rubocop:disable Lint/InheritException

          assert_raises(error_class) do
            path.writer do |io|
              io.write(data)
              raise(error_class, "stopped")
            end
          end
          assert_empty S3Stub.pending_uploads
        end

        it "makes no request when the block raises before writing a part" do
          assert_raises(IOError) { path.writer { |_io| raise(IOError, "failed") } }

          assert_empty operations(path)
        end

        it "aborts the upload, and raises the failure to upload a part" do
          client = Aws::S3::Client.new(stub_responses: true, region: "us-east-1", credentials: Aws::Credentials.new("id", "secret"))
          client.stub_responses(:create_multipart_upload, {upload_id: "1"})
          client.stub_responses(:upload_part, "AccessDenied")
          path  = IOStreams::Paths::S3.new("s3://bucket/a.bin", client: client)
          error = assert_raises(IOStreams::Errors::PermissionDenied) { path.write(data) }

          assert_instance_of Aws::S3::Errors::AccessDenied, error
          assert_includes(client.api_requests.map { |request| request[:operation_name] }, :abort_multipart_upload)
        end

        it "aborts the upload when it cannot be completed" do
          client = Aws::S3::Client.new(stub_responses: true, region: "us-east-1", credentials: Aws::Credentials.new("id", "secret"))
          client.stub_responses(:create_multipart_upload, {upload_id: "1"})
          client.stub_responses(:complete_multipart_upload, "PreconditionFailed")
          path = IOStreams::Paths::S3.new("s3://bucket/a.bin", client: client, if_none_match: "*")

          assert_raises(Aws::S3::Errors::PreconditionFailed) { path.write(data) }
          requests = client.api_requests.map { |request| request[:operation_name] }

          assert_equal :abort_multipart_upload, requests.last
          assert_equal(["*"], client.api_requests.select { |request| request[:operation_name] == :complete_multipart_upload }.map { |request| request[:params][:if_none_match] })
        end

        it "raises the exception of the block when the upload cannot be aborted" do
          client = Aws::S3::Client.new(stub_responses: true, region: "us-east-1", credentials: Aws::Credentials.new("id", "secret"))
          client.stub_responses(:create_multipart_upload, {upload_id: "1"})
          client.stub_responses(:abort_multipart_upload, "InternalError")
          path = IOStreams::Paths::S3.new("s3://bucket/a.bin", client: client)

          assert_raises(IOError) do
            path.writer do |io|
              io.write(data)
              raise(IOError, "failed")
            end
          end
        end
      end
    end
  end
end
