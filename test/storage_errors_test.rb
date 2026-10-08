require_relative "test_helper"
require_relative "s3_stub"
# The tests build AWS errors, such as Seahorse::Client::NetworkingError, before any S3 path loads the SDK.
require "aws-sdk-s3"
require_relative "http_server"
require "open3"
require "tmpdir"

# A path tags the exception that its storage raised with the kind of failure, such as `IOStreams::Errors::NotFound`,
# so that the same failure can be rescued the same way whichever storage the path is on.
class StorageErrorsTest < Minitest::Test
  # Raises Errno::ENOENT from a method of its own, so that the backtrace can be compared once it is tagged.
  def self.raise_missing
    raise(Errno::ENOENT, "missing.csv")
  end

  describe IOStreams::Errors::StorageError do
    let(:not_found) { IOStreams::Errors::NotFound }

    # Returns [Exception] the exception that the block raises.
    def raised
      yield
    rescue StandardError => e
      e
    end

    describe ".tag" do
      it "keeps the class, message and backtrace of the exception" do
        error     = raised { StorageErrorsTest.raise_missing }
        backtrace = error.backtrace

        assert_same error, not_found.tag(error, "missing.csv")
        assert_instance_of Errno::ENOENT, error
        assert_equal "No such file or directory - missing.csv", error.message
        assert_equal backtrace, error.backtrace
      end

      it "is rescued by its kind of failure, by StorageError, and by the class of the exception" do
        [not_found, IOStreams::Errors::StorageError, Errno::ENOENT].each do |rescued|
          error = assert_raises(rescued) { raise(not_found.tag(Errno::ENOENT.new("missing.csv"), "missing.csv")) }

          assert_kind_of not_found, error
        end
      end

      it "holds the display name of the path" do
        error = not_found.tag(RuntimeError.new("The specified key does not exist."), "s3://bucket/a.csv")

        assert_equal "s3://bucket/a.csv", error.display_name
      end

      it "starts the message with the display name of the path" do
        error   = not_found.tag(RuntimeError.new("The specified key does not exist."), "s3://bucket/a.csv")
        message = "s3://bucket/a.csv: The specified key does not exist."

        assert_equal message, error.message
        assert_equal message, error.to_s
        assert_includes error.inspect, message
        assert_includes error.full_message(highlight: false), message
      end

      it "does not repeat a display name that the message already includes" do
        error = not_found.tag(Errno::ENOENT.new("/data/a.csv"), "/data/a.csv")

        assert_equal "No such file or directory - /data/a.csv", error.message
      end

      it "keeps the kind of failure and display name of the path that tagged it first" do
        error = not_found.tag(RuntimeError.new("missing"), "s3://bucket/a.csv")

        assert_same error, not_found.tag(error, "s3://bucket/b.csv")
        assert_equal "s3://bucket/a.csv", error.display_name
      end

      it "leaves a frozen exception as it is" do
        error = RuntimeError.new("missing").freeze

        assert_same error, not_found.tag(error, "s3://bucket/a.csv")
        refute_kind_of IOStreams::Errors::StorageError, error
      end

      it "keeps the kind of failure and display name when the exception is marshaled" do
        error  = not_found.tag(RuntimeError.new("missing"), "s3://bucket/a.csv")
        loaded = Marshal.load(Marshal.dump(error))

        assert_kind_of not_found, loaded
        assert_equal "s3://bucket/a.csv", loaded.display_name
      end

      it "is only defined for a kind of failure" do
        assert_respond_to not_found, :tag
        refute_respond_to IOStreams::Errors::StorageError, :tag
      end
    end
  end

  # The same failure raises the same kind of failure on every storage, keeping the class that the storage raised,
  # so that a path held in configuration can change, for example from a local file to S3, without changing the code.
  describe "every storage" do
    # Asserts that the block raises NotFound for the path, keeping the class of the exception that the storage raised.
    def assert_not_found(storage_class, path, &)
      error = assert_raises(IOStreams::Errors::NotFound, &)

      assert_instance_of storage_class, error
      assert_equal path.display_name, error.display_name
      assert_includes error.message, path.display_name
    end

    # Asserts that the block raises PermissionDenied for the path, keeping the class of the exception that the storage
    # raised.
    def assert_permission_denied(storage_class, path, &)
      error = assert_raises(IOStreams::Errors::PermissionDenied, &)

      assert_instance_of storage_class, error
      assert_equal path.display_name, error.display_name
      refute_kind_of IOStreams::Errors::NotFound, error
    end

    # Returns an S3 client whose requests respond with the supplied stubs.
    def s3_client(responses)
      IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
      Aws::S3::Client.new(stub_responses: responses, region: "us-east-1", credentials: Aws::Credentials.new("id", "secret"))
    end

    # Asserts that the block raises Unavailable for the path, keeping the class of the exception that the storage
    # raised.
    def assert_unavailable(storage_class, path, &)
      error = assert_raises(IOStreams::Errors::Unavailable, &)

      assert_instance_of storage_class, error
      assert_equal path.display_name, error.display_name
    end

    # Asserts that an exception raised by the block supplied to the reader is not tagged as a failure of the path,
    # such as a file, or a server, that the block cannot reach.
    def assert_block_failure_not_tagged(path)
      [Errno::ENOENT, Errno::ECONNREFUSED].each do |error_class|
        error = assert_raises(error_class) { path.reader { |_io| raise(error_class, "config") } }

        refute_kind_of IOStreams::Errors::StorageError, error
      end
    end

    def with_s3
      IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
      S3Stub.install
      yield
    ensure
      S3Stub.uninstall
    end

    # Runs the block with a stand-in for the sftp program that prints the output, and fails unless `success`.
    def with_sftp(output = "", success: false, &)
      status = Struct.new(:success?).new(success)
      popen  = ->(*_args, &block) { block.call(StringIO.new, StringIO.new(output), Struct.new(:value).new(status)) }
      Open3.stub(:popen2e, popen, &)
    end

    # Yields the url of a server that responds to every request with the status.
    def with_http(status, body: "")
      server = TestHTTPServer.new { |_path| TestHTTPServer.response(status, body: body) }
      yield(server.base_url)
    ensure
      server&.shutdown
    end

    describe "reading a file that does not exist" do
      it "raises NotFound for a local file" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "missing.csv")

          assert_not_found(Errno::ENOENT, path) { path.read }
        end
      end

      it "raises NotFound for S3" do
        with_s3 do
          path = IOStreams.path("s3://iostreams-test/missing.csv")

          assert_not_found(Aws::S3::Errors::NoSuchKey, path) { path.read }
        end
      end

      it "raises NotFound for SFTP" do
        path = IOStreams.path("sftp://example.org/data/missing.csv", username: "jack")

        with_sftp('File "/data/missing.csv" not found.') do
          assert_not_found(IOStreams::Errors::CommunicationsFailure, path) { path.read }
        end
      end

      it "raises NotFound for HTTP" do
        with_http(404) do |url|
          path = IOStreams.path("#{url}/missing.csv")

          assert_not_found(IOStreams::Errors::CommunicationsFailure, path) { path.read }
        end
      end
    end

    describe "the size of a file that does not exist" do
      it "raises NotFound for a local file, while #size? is nil" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "missing.csv")

          assert_not_found(Errno::ENOENT, path) { path.size }
          assert_nil path.size?
        end
      end

      it "raises NotFound for S3, while #size? is nil" do
        with_s3 do
          path = IOStreams.path("s3://iostreams-test/missing.csv")

          assert_not_found(Aws::S3::Errors::NotFound, path) { path.size }
          assert_nil path.size?
        end
      end

      it "raises NotFound for HTTP, while #size? is nil" do
        with_http(404) do |url|
          path = IOStreams.path("#{url}/missing.csv")

          assert_not_found(IOStreams::Errors::CommunicationsFailure, path) { path.size }
          assert_nil path.size?
        end
      end
    end

    describe "writing to a directory, or S3 bucket, that does not exist" do
      it "raises NotFound for a local file" do
        Dir.mktmpdir do |dir|
          path = IOStreams::Paths::File.new(File.join(dir, "missing", "a.csv"), create_path: false)

          assert_not_found(Errno::ENOENT, path) { path.write("data") }
        end
      end

      it "raises NotFound for S3" do
        IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
        client = Aws::S3::Client.new(stub_responses: {put_object: "NoSuchBucket"})
        path   = IOStreams.path("s3://missing-bucket/a.csv", client: client)

        assert_not_found(Aws::S3::Errors::NoSuchBucket, path) { path.write("data") }
      end

      it "raises NotFound for SFTP" do
        path = IOStreams.path("sftp://example.org/missing/a.csv", username: "jack")

        with_sftp('dest open "/missing/a.csv": No such file or directory') do
          assert_not_found(IOStreams::Errors::CommunicationsFailure, path) { path.write("data") }
        end
      end

      it "raises NotFound for HTTP" do
        with_http(404) do |url|
          path = IOStreams.path("#{url}/missing/a.csv")

          assert_not_found(IOStreams::Errors::CommunicationsFailure, path) { path.write("data") }
        end
      end
    end

    describe "reading a file that the storage does not permit" do
      it "raises PermissionDenied for a local file" do
        skip "Every file can be read as root" if Process.uid.zero?

        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "secret.csv")
          path.write("data")
          File.chmod(0o000, path.to_s)

          assert_permission_denied(Errno::EACCES, path) { path.read }
        end
      end

      it "raises PermissionDenied for S3" do
        path = IOStreams.path("s3://my-bucket/secret.csv", client: s3_client(get_object: "AccessDenied"))

        assert_permission_denied(Aws::S3::Errors::AccessDenied, path) { path.read }
      end

      it "raises PermissionDenied for SFTP" do
        path = IOStreams.path("sftp://example.org/data/secret.csv", username: "jack")

        with_sftp('remote open "/data/secret.csv": Permission denied') do
          assert_permission_denied(IOStreams::Errors::CommunicationsFailure, path) { path.read }
        end
      end

      it "raises PermissionDenied for HTTP" do
        with_http(403) do |url|
          path = IOStreams.path("#{url}/secret.csv")

          assert_permission_denied(IOStreams::Errors::CommunicationsFailure, path) { path.read }
        end
      end
    end

    describe "credentials that are not valid" do
      it "raise PermissionDenied for S3" do
        path = IOStreams.path("s3://my-bucket/a.csv", client: s3_client(get_object: "InvalidAccessKeyId"))

        assert_permission_denied(Aws::S3::Errors::InvalidAccessKeyId, path) { path.read }
      end

      it "raise PermissionDenied for SFTP" do
        path = IOStreams.path("sftp://example.org/data/a.csv", username: "jack")

        with_sftp("jack@example.org: Permission denied (publickey).\nConnection closed") do
          assert_permission_denied(IOStreams::Errors::CommunicationsFailure, path) { path.read }
        end
      end

      it "raise PermissionDenied for HTTP" do
        with_http(401) do |url|
          path = IOStreams.path("#{url}/a.csv", username: "jack", password: "wrong")

          assert_permission_denied(IOStreams::Errors::CommunicationsFailure, path) { path.read }
        end
      end
    end

    describe "a storage that cannot be reached" do
      it "raises Unavailable for S3" do
        error = Seahorse::Client::NetworkingError.new(Errno::ECONNREFUSED.new("connect"))
        path  = IOStreams.path("s3://my-bucket/a.csv", client: s3_client(get_object: error))

        assert_unavailable(Seahorse::Client::NetworkingError, path) { path.read }
      end

      it "raises Unavailable for SFTP" do
        path = IOStreams.path("sftp://example.org/data/a.csv", username: "jack")

        with_sftp("ssh: connect to host example.org port 22: Connection refused\nConnection closed") do
          assert_unavailable(IOStreams::Errors::CommunicationsFailure, path) { path.read }
        end
      end

      it "raises Unavailable for HTTP" do
        server = TCPServer.new("127.0.0.1", 0)
        port   = server.addr[1]
        server.close
        path = IOStreams.path("http://127.0.0.1:#{port}/a.csv")

        assert_unavailable(Errno::ECONNREFUSED, path) { path.read }
      end
    end

    describe "a storage that cannot handle the request at the time" do
      it "raises Unavailable for S3" do
        slow_down = {status_code: 503, headers: {}, body: "<Error><Code>SlowDown</Code><Message>Reduce</Message></Error>"}
        path      = IOStreams.path("s3://my-bucket/a.csv", client: s3_client(get_object: slow_down))

        assert_unavailable(Aws::S3::Errors::SlowDown, path) { path.read }
      end

      it "raises Unavailable for HTTP" do
        with_http(503) do |url|
          path = IOStreams.path("#{url}/a.csv")

          assert_unavailable(IOStreams::Errors::CommunicationsFailure, path) { path.read }
        end
      end
    end

    it "raises AccessDenied, which is not a failure of the storage, for a path outside the allowed paths" do
      Dir.mktmpdir do |dir|
        IOStreams.add_allowed_path(dir)
        error = assert_raises(IOStreams::Errors::AccessDenied) { IOStreams.path(__FILE__).read }

        refute_kind_of IOStreams::Errors::StorageError, error
      ensure
        IOStreams.delete_allowed_path(dir)
      end
    end

    describe "an exception raised by the block while reading" do
      it "is not tagged for a local file" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "a.csv")
          path.write("data")

          assert_block_failure_not_tagged(path)
        end
      end

      it "is not tagged for S3" do
        with_s3 do
          path = IOStreams.path("s3://iostreams-test/a.csv")
          path.write("data")

          assert_block_failure_not_tagged(path)
        end
      end

      it "is not tagged for SFTP" do
        path = IOStreams.path("sftp://example.org/data/a.csv", username: "jack")

        with_sftp(success: true) { assert_block_failure_not_tagged(path) }
      end

      it "is not tagged for HTTP" do
        with_http(200, body: "data") do |url|
          assert_block_failure_not_tagged(IOStreams.path("#{url}/a.csv"))
        end
      end
    end
  end
end
