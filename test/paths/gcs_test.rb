# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../s3_stub"

module Paths
  class GCSTest < Minitest::Test
    # Runs against the Cloud Storage bucket in the 'GCS_BUCKET_NAME' environment variable when it is set, with the HMAC
    # key in 'GCS_ACCESS_KEY_ID' and 'GCS_SECRET_ACCESS_KEY', otherwise against an in-memory store.
    describe IOStreams::Paths::GCS do
      before do
        IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
        S3Stub.install unless ENV["GCS_BUCKET_NAME"]
      end

      after do
        directory.delete_all
      ensure
        S3Stub.uninstall unless ENV["GCS_BUCKET_NAME"]
      end

      let :credentials do
        {access_key_id: ENV.fetch("GCS_ACCESS_KEY_ID", nil), secret_access_key: ENV.fetch("GCS_SECRET_ACCESS_KEY", nil)}.compact
      end

      let(:root_path) { IOStreams.path("gs://#{ENV.fetch('GCS_BUCKET_NAME', 'iostreams-test')}/iostreams_test", **credentials) }

      let(:directory) { root_path.join("gcs_test") }

      it "writes, reads and deletes an object" do
        path = directory.join("a.txt")
        path.write("Hello World")

        assert_equal "Hello World", path.read
        assert_predicate path, :exist?
        assert_predicate path, :file?
        assert_equal 11, path.size
        assert_kind_of Time, path.mtime
        assert_same path, path.delete
        refute_predicate path, :exist?
      end

      it "writes and reads an object larger than a part and a range, in parts and ranges" do
        size = IOStreams::Paths::S3::Uploader::PART_SIZE + IOStreams::Paths::S3::RangeReader::RANGE_SIZE + 10
        data = Random.new(42).bytes(size)
        path = directory.join("large.bin")
        path.write(data)

        assert_equal size, path.size
        assert_equal data, path.read.b
      end

      it "writes an object with its metadata" do
        path = IOStreams.path(directory.join("b.csv").to_s, **credentials,
                              content_type: "text/csv", cache_control: "no-cache", metadata: {"source" => "test"})
        path.write("a,b\n1,2\n")

        assert_equal "a,b\n1,2\n", path.read
      end

      it "raises NotFound for an object that does not exist" do
        path  = directory.join("missing.txt")
        error = assert_raises(IOStreams::Errors::NotFound) { path.read }

        assert_equal path.display_name, error.display_name
        refute_predicate path, :exist?
        assert_nil path.size?
      end

      it "lists the children and directories within a path" do
        directory.join("a.csv").write("a")
        directory.join("b.txt").write("b")
        directory.join("sub/c.csv").write("c")

        assert_equal %w[a.csv b.txt], directory.children("*").map(&:basename).sort
        assert_equal %w[a.csv sub/c.csv], directory.children("**/*.csv").map { |child| child.relative_path_from(directory).to_s }.sort
        assert_equal %w[a.csv b.txt sub], directory.children("*", directories: true).map(&:basename).sort
        assert_predicate directory.join("sub"), :directory?
        assert(directory.children("*").all?(IOStreams::Paths::GCS))
      end

      it "copies an object within Cloud Storage, and moves it" do
        source = directory.join("source a+b %41.txt")
        target = directory.join("target.txt")
        source.write("Hello World")

        assert_equal 11, target.copy_from(source, convert: false)
        assert_equal "Hello World", target.read

        moved = target.move_to(directory.join("moved.txt"))

        assert_equal "Hello World", moved.read
        refute_predicate target, :exist?
      end

      it "copies an object to and from a local file" do
        IOStreams.temp_file("gcs_test", ".csv") do |local|
          local.write("name\nJack\n")
          path = directory.join("copy.csv")
          path.copy_from(local)

          assert_equal "name\nJack\n", path.read

          IOStreams.temp_file("gcs_test", ".csv") do |copy|
            copy.copy_from(path)

            assert_equal "name\nJack\n", copy.read
          end
        end
      end

      it "deletes every object within a path, but not one that only starts with the same characters" do
        directory.join("delete/a.txt").write("a")
        directory.join("delete/sub/b.txt").write("b")
        sibling = directory.join("delete.txt")
        sibling.write("c")

        directory.join("delete").delete_all

        refute_predicate directory.join("delete"), :exist?
        assert_predicate sibling, :exist?
      end
    end

    # Unit tests with a stubbed client, which check what is particular to Cloud Storage.
    describe "IOStreams::Paths::GCS without a connection" do
      # Returns [Array<Hash>] the method, url and headers of each request that the client signs, and the name of its
      # operation, recorded once it is signed.
      def capture_requests(client)
        requests = []
        lock     = Mutex.new
        client.handlers.add(Class.new(Seahorse::Client::Handler) do
          define_method(:call) do |context|
            request = context.http_request
            lock.synchronize do
              requests << {operation: context.operation_name, method: request.http_method, url: request.endpoint.to_s,
                           headers: request.headers.to_h, params: context.params}
            end
            @handler.call(context)
          end
        end, step: :sign, priority: 0)
        requests
      end

      let :client do
        IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
        IOStreams.path("gs://bucket", client: {stub_responses: true}).client
      end

      describe "the scheme" do
        it "is gs://, whatever its case" do
          path = IOStreams.path("GS://my-bucket/exports/daily.csv")

          assert_instance_of IOStreams::Paths::GCS, path
          assert_equal "gs://my-bucket/exports/daily.csv", path.to_s
          assert_equal "my-bucket", path.bucket_name
          assert_equal "exports/daily.csv", path.path
          assert_equal IOStreams::Paths::GCS, IOStreams.scheme(:gs)
        end

        it "is not gcs://" do
          error = assert_raises(ArgumentError) { IOStreams.path("gcs://my-bucket/a.csv") }

          assert_equal 'Unknown Scheme type: "gcs"', error.message
        end

        it "keeps the scheme in the paths joined to it, its directory and its children" do
          client.stub_responses(:list_objects_v2, {contents: [{key: "exports/a.csv"}]})
          path = IOStreams.path("gs://bucket/exports", client: client)

          assert_equal "gs://bucket/exports/a.csv", path.join("a.csv").to_s
          assert_equal "gs://bucket/", path.directory.to_s
          assert_equal ["gs://bucket/exports/a.csv"], path.children("*").map(&:to_s)
          assert_instance_of IOStreams::Paths::GCS, path.children("*").first
        end

        it "is another object than the S3 object of the same bucket and key" do
          gcs = IOStreams.path("gs://bucket/a.csv")
          s3  = IOStreams.path("s3://bucket/a.csv")

          refute_equal gcs, s3
          refute_equal s3, gcs
          assert_equal gcs, IOStreams.path("gs://bucket/a.csv", content_type: "text/csv")
          assert_raises(ArgumentError) { IOStreams.path("gs://bucket/exports/a.csv").relative_path_from(s3) }
        end

        it "displays the path with its class" do
          assert_equal "#<IOStreams::Paths::GCS:gs://bucket/a.csv.gz pipeline=#{{gz: {}}.inspect}>", IOStreams.path("gs://bucket/a.csv.gz").inspect
        end
      end

      describe "the client" do
        it "connects to Cloud Storage, with the bucket in the path, signed in the region auto" do
          path   = IOStreams.path("gs://my.bucket/a b.csv", client: client)
          config = client.config

          assert_equal "https://storage.googleapis.com", config.endpoint.to_s
          assert_equal "auto", config.region
          assert config.force_path_style

          requests = capture_requests(client)
          path.write("data")
          request = requests.first

          assert_equal "https://storage.googleapis.com/my.bucket/a%20b.csv", request[:url]
          assert_match %r{/auto/s3/aws4_request}, request[:headers]["authorization"]
        end

        it "computes and checks a checksum only for a request that requires one" do
          config = client.config

          assert_equal "when_required", config.request_checksum_calculation
          assert_equal "when_required", config.response_checksum_validation

          client.stub_responses(:get_object, {body: "data"})
          path     = IOStreams.path("gs://bucket/a.csv", client: client)
          requests = capture_requests(client)
          path.write("data")
          path.read

          requests.each do |request|
            assert_empty request[:headers].keys.grep(/checksum/), request[:operation]
          end
        end

        it "leaves out the checksum settings with a version of the AWS SDK that does not have them" do
          IOStreams::Paths::S3::Sdk.stub(:client_option?, false) do
            config = IOStreams.path("gs://bucket/a.csv", client: {stub_responses: true}).client.config

            assert_equal "https://storage.googleapis.com", config.endpoint.to_s
            # The default of the AWS SDK.
            assert_equal "when_supported", config.request_checksum_calculation
          end
        end

        it "is created with the HMAC key that is supplied" do
          path        = IOStreams.path("gs://bucket/a.csv", access_key_id: "GOOG1EXAMPLE", secret_access_key: "secret")
          credentials = path.client.config.credentials

          assert_equal "GOOG1EXAMPLE", credentials.access_key_id
          assert_equal "secret", credentials.secret_access_key
        end

        it "is created with the options of a client Hash, which override those of Cloud Storage" do
          path = IOStreams.path("gs://bucket/a.csv", client: {stub_responses: true, endpoint: "https://storage.example.com"})

          assert_equal "https://storage.example.com", path.client.config.endpoint.to_s
          assert_equal "auto", path.client.config.region
        end

        it "uses a client that is supplied as it is" do
          IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
          supplied = Aws::S3::Client.new(stub_responses: true, region: "us-east-1")

          assert_same supplied, IOStreams.path("gs://bucket/a.csv", client: supplied).client
        end

        it "is shared by the paths joined to it" do
          path = IOStreams.path("gs://bucket/exports", client: {stub_responses: true})

          assert_same path.client, path.join("a.csv").client
        end

        it "does not display the secret of the HMAC key" do
          options = IOStreams.redact_path_options("gs://bucket/a.csv", access_key_id: "GOOG1EXAMPLE", secret_access_key: "secret")

          assert_equal({access_key_id: "GOOG1EXAMPLE", secret_access_key: "[FILTERED]"}, options)
        end
      end

      describe "options" do
        it "supplies the metadata of the object when it is written" do
          path     = IOStreams.path("gs://bucket/a.csv?content_type=text/csv", client: client,
                                    cache_control: "no-cache", metadata: {"source" => "test"}, storage_class: "NEARLINE")
          requests = capture_requests(client)
          path.write("data")
          params = requests.first[:params]

          assert_equal :put_object, requests.first[:operation]
          assert_equal "text/csv", params[:content_type]
          assert_equal "no-cache", params[:cache_control]
          assert_equal({"source" => "test"}, params[:metadata])
          assert_equal "NEARLINE", params[:storage_class]
        end

        it "supplies the metadata of the object to an upload in parts" do
          client.stub_responses(:create_multipart_upload, {upload_id: "1"})
          path     = IOStreams.path("gs://bucket/a.bin", client: client, content_type: "application/octet-stream")
          requests = capture_requests(client)
          path.write("x" * (IOStreams::Paths::S3::Uploader::PART_SIZE + 1))
          operations = requests.map { |request| request[:operation] }

          assert_equal %i[complete_multipart_upload create_multipart_upload upload_part], operations.uniq.sort
          assert_equal "application/octet-stream", requests.first[:params][:content_type]
        end

        it "does not supply the metadata of the object when it is read" do
          client.stub_responses(:get_object, {body: "data"})
          path     = IOStreams.path("gs://bucket/a.csv", client: client, content_type: "text/csv")
          requests = capture_requests(client)

          assert_equal "data", path.read
          refute requests.first[:params].key?(:content_type)
        end

        it "raises for an option that is not the metadata of an object, including those of S3 and region:" do
          %i[acl request_payer sse_customer_key region acll].each do |option|
            error = assert_raises(ArgumentError) { IOStreams.path("gs://bucket/a.csv", option => "value") }

            assert_equal "Unknown GCS option: #{option.inspect}", error.message
          end
        end

        it "checks the options without the AWS SDK, so that they are checked wherever the path is created" do
          IOStreams::Paths::S3::Sdk.stub(:available?, false) do
            assert_raises(ArgumentError) { IOStreams.path("gs://bucket/a.csv", acl: "private") }
            assert_raises(ArgumentError) { IOStreams.path("gs://bucket/a.csv?acl=private") }
          end
        end

        it "raises for a part of the query of the url that is not an option" do
          error = assert_raises(ArgumentError) { IOStreams.path("gs://bucket/data/file?.csv") }

          assert_equal %(Invalid GCS url "gs://bucket/data/file": its query holds the options of its requests, but ".csv" ) +
                       %(is not one of the GCS options. Percent-encode a '?' in a key as '%3F'), error.message

          error = assert_raises(ArgumentError) { IOStreams.path("gs://bucket/a.txt?bogus=1&key=2") }

          assert_equal %(Invalid GCS url "gs://bucket/a.txt": its query holds the options of its requests, but "bogus", ) +
                       %("key" are not GCS options), error.message
        end
      end

      describe "the url" do
        it "raises ArgumentError for a part of the url that Cloud Storage does not use, rather than ignore it" do
          {
            "gs://bucket/a#b.csv"            => %(Invalid GCS url "gs://bucket/a": percent-encode a '#' in a key as '%23'),
            "gs://bucket:9000/a.csv"         => %(Invalid GCS url "gs://bucket:9000/a.csv": it cannot have a port. Supply the endpoint),
            "gs://GOOG1:SECRET@bucket/a.csv" => %(Invalid GCS url "gs://bucket/a.csv": it cannot have a user name or password),
            "gs:///a.csv"                    => %(Invalid GCS url "gs:///a.csv": it must name a bucket, such as 'gs://bucket/a.csv')
          }.each_pair do |url, message|
            error = assert_raises(ArgumentError, url) { IOStreams.path(url) }

            assert_includes error.message, message, url
            refute_includes error.message, "SECRET"
          end
          error = assert_raises(ArgumentError) { IOStreams.path("gs://bucket/a#b.csv") }

          assert_includes error.message, "which GCS urls cannot have"
        end

        it "raises for a name that is not valid UTF-8, which Cloud Storage cannot hold" do
          error = assert_raises(ArgumentError) { IOStreams.path("gs://bucket/in").join("caf\xE9.csv".b) }

          assert_equal "GCS keys must be valid UTF-8: gs://bucket/in/caf\\xE9.csv", error.message
        end

        it "percent-encodes each %, ? and # in the key in its url, so that it can be created again from its url" do
          path = IOStreams.path("gs://bucket/reports").join("100% a?b#c.csv")

          assert_equal "gs://bucket/reports/100%25 a%3Fb%23c.csv", path.to_s
          assert_equal path.path, IOStreams.path(path.to_s).path
        end
      end

      describe "copies" do
        before do
          IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
          S3Stub.install
          IOStreams.path("gs://bucket/source.csv").write("data")
          IOStreams.path("s3://bucket/source.csv").write("data")
        end

        after do
          S3Stub.uninstall
        end

        it "copies directly within Cloud Storage" do
          source = IOStreams.path("gs://bucket/source.csv")
          target = IOStreams.path("gs://bucket/target.csv")
          requests = capture_requests(target.client)

          assert_equal 4, target.copy_from(source, convert: false)
          assert_includes requests.map { |request| request[:operation] }, :copy_object
          assert_equal "data", target.read
        end

        it "replaces the metadata of the source with that of the target, which Cloud Storage otherwise keeps" do
          source   = IOStreams.path("gs://bucket/source.csv")
          target   = IOStreams.path("gs://bucket/target.csv", content_type: "text/csv", metadata: {"source" => "x"})
          requests = capture_requests(target.client)
          target.copy_from(source, convert: false)
          copy = requests.find { |request| request[:operation] == :copy_object }

          assert_equal "REPLACE", copy[:params][:metadata_directive]
          assert_equal "text/csv", copy[:params][:content_type]
          assert_equal({"source" => "x"}, copy[:params][:metadata])
        end

        it "keeps the metadata of the source when the target supplies none, or only its storage class" do
          source = IOStreams.path("gs://bucket/source.csv")
          [{}, {storage_class: "NEARLINE"}].each do |options|
            target   = IOStreams.path("gs://bucket/target.csv", **options)
            requests = capture_requests(target.client)
            target.copy_from(source, convert: false)
            copy = requests.find { |request| request[:operation] == :copy_object }

            refute copy[:params].key?(:metadata_directive), options.inspect
          end
        end

        it "reads and writes rather than copying directly between Cloud Storage and S3, which are other services" do
          [%w[gs s3], %w[s3 gs]].each do |source_scheme, target_scheme|
            source   = IOStreams.path("#{source_scheme}://bucket/source.csv")
            target   = IOStreams.path("#{target_scheme}://bucket/target_#{target_scheme}.csv")
            requests = [source.client, target.client].map { |path_client| capture_requests(path_client) }

            assert_equal 4, target.copy_from(source, convert: false)
            operations = requests.flatten.map { |request| request[:operation] }

            refute_includes operations, :copy_object, "#{source_scheme} to #{target_scheme}"
            assert_includes operations, :get_object
            assert_includes operations, :put_object
          end
        end
      end

      describe "failures" do
        def stub_client(responses)
          IOStreams.path("gs://bucket", client: {stub_responses: responses}).client
        end

        it "raises NotFound for an object or a bucket that does not exist" do
          path  = IOStreams.path("gs://bucket/a.csv", client: stub_client(get_object: "NoSuchKey"))
          error = assert_raises(IOStreams::Errors::NotFound) { path.read }

          assert_instance_of Aws::S3::Errors::NoSuchKey, error
          assert_equal "gs://bucket/a.csv", error.display_name

          path  = IOStreams.path("gs://missing-bucket/reports", client: stub_client(list_objects_v2: "NoSuchBucket"))
          error = assert_raises(IOStreams::Errors::NotFound) { path.children("*.csv") }

          assert_equal "gs://missing-bucket/reports", error.display_name
        end

        it "raises PermissionDenied for the errors of Cloud Storage that mean the request has no valid credentials" do
          %w[AccessDenied AuthenticationRequired AuthenticationRequiredRequesterPays InvalidAuthentication InvalidSecurity
             SignatureDoesNotMatch].each do |code|
            path  = IOStreams.path("gs://bucket/a.csv", client: stub_client(get_object: code))
            error = assert_raises(IOStreams::Errors::PermissionDenied, code) { path.read }

            assert_equal code, error.code
          end
        end

        it "raises PermissionDenied for those errors of Cloud Storage within the failure of an upload in parts" do
          client = stub_client(upload_part: "InvalidSecurity")
          # The AWS SDK only sets the code of an error that it raised for a response.
          part   = assert_raises(Aws::S3::Errors::InvalidSecurity) do
            client.upload_part(bucket: "bucket", key: "a.csv", upload_id: "1", part_number: 1, body: "data")
          end
          parts  = Aws::S3::MultipartUploadError.new("multipart upload failed", [part])
          path   = IOStreams.path("gs://bucket/a.csv", client: client)

          IOStreams.temp_file("gcs_test", ".csv") do |file|
            file.write("a" * (IOStreams::Paths::S3::MULTIPART_UPLOAD_SIZE + 1))
            # The AWS SDK only uploads a file in parts once it is larger than 100MB.
            IOStreams::Paths::S3::Sdk.stub(:upload_file, ->(*, **) { raise(parts) }) do
              error = assert_raises(IOStreams::Errors::PermissionDenied) { path.write_file(file.to_s) }

              assert_same parts, error
            end
          end

          assert_nil IOStreams::Paths::S3::Failure.kind(parts), "S3 does not have the code"
        end

        it "raises Unavailable when Cloud Storage limits the rate of requests" do
          too_many = {status_code: 429, headers: {}, body: "<Error><Code>RateLimitExceeded</Code></Error>"}
          path     = IOStreams.path("gs://bucket/a.csv", client: stub_client(put_object: too_many))

          assert_raises(IOStreams::Errors::Unavailable) { path.write("data") }
        end

        it "does not tag any other failure" do
          path  = IOStreams.path("gs://bucket/a.csv", client: stub_client(get_object: "InvalidArgument"))
          error = assert_raises(Aws::S3::Errors::InvalidArgument) { path.read }

          refute_kind_of IOStreams::Errors::StorageError, error
        end
      end

      describe "allowed paths" do
        before do
          IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
          S3Stub.install
          IOStreams.add_allowed_path("gs://bucket/allowed")
        end

        after do
          IOStreams.delete_allowed_path("gs://bucket/allowed")
          S3Stub.uninstall
        end

        it "allows a path within an allowed gs:// path, and denies the S3 object of the same bucket and key" do
          IOStreams.path("gs://bucket/allowed/a.txt").write("allowed")

          assert_equal "allowed", IOStreams.path("gs://bucket/allowed/a.txt").read
          assert_raises(IOStreams::Errors::AccessDenied) { IOStreams.path("s3://bucket/allowed/a.txt").read }
          assert_raises(IOStreams::Errors::AccessDenied) { IOStreams.path("gs://bucket/other/a.txt").read }
          assert_raises(IOStreams::Errors::AccessDenied) { IOStreams.path("gs://bucket/allowed/../a.txt").read }
        end
      end
    end
  end
end
