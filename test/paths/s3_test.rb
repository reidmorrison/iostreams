require_relative "../test_helper"
require_relative "../s3_stub"
require "digest"

module Paths
  class S3Test < Minitest::Test
    # Runs against the bucket in the 'S3_BUCKET_NAME' environment variable when it is set,
    # otherwise against an in-memory S3.
    describe IOStreams::Paths::S3 do
      before do
        IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
        S3Stub.install unless ENV["S3_BUCKET_NAME"]
      end

      after do
        S3Stub.uninstall unless ENV["S3_BUCKET_NAME"]
      end

      let :file_name do
        File.join(File.dirname(__FILE__), "..", "files", "text file.txt")
      end

      let :raw do
        File.read(file_name)
      end

      let(:root_path) { IOStreams::Paths::S3.new("s3://#{ENV.fetch('S3_BUCKET_NAME', 'iostreams-test')}/iostreams_test") }

      let :existing_path do
        path = root_path.join("test.txt")
        path.write(raw) unless path.exist?
        path
      end

      let :missing_path do
        root_path.join("unknown.txt")
      end

      let :write_path do
        root_path.join("writer_test.txt").delete
      end

      describe "#delete" do
        it "existing file" do
          assert_kind_of IOStreams::Paths::S3, existing_path.delete
        end

        it "missing file" do
          assert_kind_of IOStreams::Paths::S3, missing_path.delete
        end
      end

      describe "#exist?" do
        it "existing file" do
          assert_predicate existing_path, :exist?
        end

        it "missing file" do
          refute_predicate missing_path, :exist?
        end
      end

      describe "#mkpath" do
        it "returns self for non-existant path" do
          assert_kind_of IOStreams::Paths::S3, existing_path.mkpath
        end

        it "checks for lack of existence" do
          assert_kind_of IOStreams::Paths::S3, missing_path.mkpath
        end
      end

      describe "#mkdir" do
        it "returns self for non-existant path" do
          assert_kind_of IOStreams::Paths::S3, existing_path.mkdir
        end

        it "checks for lack of existence" do
          assert_kind_of IOStreams::Paths::S3, missing_path.mkdir
        end
      end

      describe "#reader" do
        it "reads" do
          assert_equal raw, existing_path.read
        end

        it "reports a deprecation warning for a method of the File that it reads, which v3.0 does not supply" do
          line = __LINE__ + 4
          data = existing_path.reader do |io|
            first = io.read
            assert_deprecated(/s3_test\.rb:#{line}: warning: IOStreams: #rewind is deprecated on the IO of an S3 path that #reader yields, since in v3\.0 it is a stream that only reads, with #read, #readpartial, #gets, #readline, #readlines, #each_line, #each and #eof\?: read it with those, open the reader again to read it from the start, or copy the data into a local file first, such as with IOStreams\.temp_file and #copy_to, where it must be a File\n\z/) do
              io.rewind
            end
            assert_kind_of ::File, io
            assert_kind_of String, assert_deprecated(/#path is deprecated on the IO of an S3 path/) { io.path }
            assert_equal raw.bytesize, assert_deprecated(/#size is deprecated on the IO of an S3 path/) { io.size }
            [first, io.read]
          end

          assert_equal [raw, raw], data
        end

        it "reports a deprecation warning for a method of the File that it reads as it is stored" do
          path = root_path.join("test.csv.gz")
          path.write(raw)
          data = path.raw.reader do |io|
            assert_deprecated(/#rewind is deprecated on the IO of an S3 path/) { io.rewind }
            io.read
          end

          assert_equal raw, Zlib.gunzip(data)
        end

        it "reports a deprecation warning for a method of the stream of the object, or of PGP that reads it" do
          gzipped = root_path.join("test.csv.gz")
          gzipped.write(raw)
          encrypted = root_path.join("test.csv.pgp").option(:pgp, recipient: "receiver@example.org")
          encrypted.write(raw)

          gzipped.reader { |io| assert_deprecated(/#rewind is deprecated on the :gz stream/) { io.rewind } }
          root_path.join("test.csv.pgp").option(:pgp, passphrase: "receiver_passphrase").reader do |io|
            assert_deprecated(/#fileno is deprecated on the :pgp stream that #reader yields/) { io.fileno }
          end
        end

        it "reports none for the methods of an IO that read" do
          data = refute_deprecated { existing_path.reader { |io| [io.gets, io.read, io.eof?] } }

          assert_equal [raw.lines.first, raw.lines.drop(1).join, true], data
        end

        it "reports none with the range option, which v3.0 still reads from a temp File" do
          path = IOStreams.path(existing_path.to_s, range: "bytes=0-4")
          data = refute_deprecated { path.reader { |io| io.read && io.rewind && io.read } }

          assert_kind_of String, data
        end
      end

      describe "#size" do
        it "existing file" do
          assert_equal raw.size, existing_path.size
        end

        it "missing file" do
          assert_nil missing_path.size
        end
      end

      describe "#writer" do
        it "writes" do
          assert_equal(raw.size, write_path.writer { |io| io.write(raw) })
          assert_predicate write_path, :exist?
          assert_equal raw, write_path.read
        end

        it "reports a deprecation warning for a method of the File that it writes, which v3.0 does not supply" do
          size = write_path.writer do |io|
            io.write(raw)

            assert_kind_of ::File, io
            assert_kind_of String, assert_deprecated(/IOStreams: #path is deprecated on the IO of an S3 path that #writer yields, since in v3\.0 it is a stream that only writes, with #write, #<<, #print, #puts and #printf: write it with those, or write a local file first, such as with IOStreams\.temp_file, and copy it with #copy_to, where it must be a File\n\z/) { io.path }
            assert_deprecated(/#size is deprecated on the IO of an S3 path that #writer yields/) { io.size }
          end

          assert_equal raw.bytesize, size
          assert_equal raw, write_path.read
        end

        it "reports none for the methods of an IO that write, and #flush" do
          refute_deprecated do
            write_path.writer do |io|
              io.write("a")
              io << "b"
              io.print("c")
              io.printf("%d", 1)
              io.puts
              io.flush
            end
          end

          assert_equal "abc1\n", write_path.read
        end

        it "reports none with an option that describes the whole object, which v3.0 still writes into a temp File" do
          path = IOStreams.path(write_path.to_s, content_md5: Digest::MD5.base64digest(raw))
          name = refute_deprecated { path.writer { |io| io.write(raw) && io.path } }

          assert_kind_of String, name
          assert_equal raw, write_path.read
        end
      end

      describe "#each_line" do
        it "reads line by line" do
          lines = []
          existing_path.each(:line) { |line| lines << line }

          assert_equal raw.lines.collect(&:chomp), lines
        end
      end

      describe "#each_child" do
        # TODO: case_sensitive: false, directories: false, hidden: false
        let(:abd_file_names) { %w[abd/test1.txt abd/test5.file abd/extra/file.csv] }
        let(:files_for_test) { abd_file_names + %w[xyz/test2.csv xyz/another.csv] }

        let :each_root do
          root_path.join("each_child_test")
        end

        let :multiple_paths do
          files_for_test.collect { |file_name| each_root.join(file_name) }
        end

        let :write_raw_data do
          multiple_paths.each { |path| path.write(raw) unless path.exist? }
        end

        it "existing file returns just the file itself" do
          # Glorified exists call
          existing_path

          assert_equal root_path.join("test.txt").to_s, root_path.children("test.txt").first.to_s
        end

        it "missing file does nothing" do
          # Glorified exists call
          assert_equal [], missing_path.children("readme").collect(&:to_s)
        end

        it "returns all the children" do
          write_raw_data

          assert_equal multiple_paths.collect(&:to_s).sort, each_root.children("**/*").collect(&:to_s).sort
        end

        it "returns all the children under a sub-dir" do
          write_raw_data
          expected = %w[abd/test1.txt abd/test5.file].collect { |file_name| each_root.join(file_name) }

          assert_equal expected.collect(&:to_s).sort, each_root.children("abd/*").collect(&:to_s).sort
        end

        it "missing path" do
          count = 0
          missing_path.each_child { |_| count += 1 }

          assert_equal 0, count
        end

        # Test is here since all the test artifacts have been created already in S3.
        describe "IOStreams.each_child" do
          it "returns all the children" do
            write_raw_data
            children = []
            IOStreams.each_child(each_root.join("**/*").to_s) { |child| children << child }

            assert_equal multiple_paths.collect(&:to_s).sort, children.collect(&:to_s).sort
          end
        end
      end

      describe "#move_to" do
        it "moves existing file" do
          source = root_path.join("move_test_source.txt")
          begin
            source.write("Hello World")
            target   = source.directory.join("move_test_target.txt")
            response = source.move_to(target)

            assert_equal target, response
            assert_predicate target, :exist?
            refute_predicate source, :exist?
            assert_equal "Hello World", response.read
            assert_equal target.to_s, response.to_s
          ensure
            source&.delete
            target&.delete
          end
        end

        it "missing source file" do
          source = root_path.join("move_test_source.txt")

          refute_predicate source, :exist?
          begin
            target = source.directory.join("move_test_target.txt")
            assert_raises Aws::S3::Errors::NoSuchKey do
              source.move_to(target)
            end
            refute_predicate target, :exist?
          ensure
            source&.delete
            target&.delete
          end
        end

        it "missing target directories" do
          source = root_path.join("move_test_source.txt")
          begin
            source.write("Hello World")
            target   = source.directory.join("a/b/c/move_test_target.txt")
            response = source.move_to(target)

            assert_equal target, response
            assert_predicate target, :exist?
            refute_predicate source, :exist?
            assert_equal "Hello World", response.read
            assert_equal target.to_s, response.to_s
          ensure
            source&.delete
            target&.delete
          end
        end
      end

      describe "#copy_from" do
        let(:target) { root_path.join("copy_test_target.txt") }

        before do
          target.write("existing")
        end

        after do
          target.delete
        end

        it "keeps an existing object when the source cannot be read" do
          assert_raises(Errno::ENOENT) { target.copy_from(IOStreams.join("copy_test", "missing.txt")) }

          assert_equal "existing", target.read
        end

        it "keeps an existing object when the copy fails part way, since the object is only written once it completes" do
          failing_source = Object.new
          def failing_source.read(*)
            raise(IOError, "failed part way")
          end

          assert_raises(IOError) { target.copy_from(failing_source) }

          assert_equal "existing", target.read
        end
      end

      describe "#copy_to" do
        it "reports a deprecation warning for mode: and other options supplied to a copy within S3 with convert: false" do
          source = root_path.join("copy_test_source.txt")
          target = root_path.join("copy_test_target.txt")
          source.write("Hello World")
          assert_deprecated(/mode:, columns: are deprecated for a copy with convert: false, which ignores them/) do
            source.copy_to(target, convert: false, mode: :hash, columns: ["name"])
          end

          assert_equal "Hello World", target.read
        ensure
          source&.delete
          target&.delete
        end
      end

      describe "#partial_files_visible?" do
        it "visible only after upload" do
          refute_predicate root_path, :partial_files_visible?
        end
      end
    end

    # Unit tests that use a stubbed S3 client, so they run in every environment.
    describe "IOStreams::Paths::S3 without a connection" do
      let :client do
        IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
        client = Aws::S3::Client.new(stub_responses: true, region: "us-east-1", credentials: Aws::Credentials.new("id", "secret"))
        client.stub_responses(
          :list_objects_v2,
          {
            name:     "bucket",
            contents: [{key: "inbox/a+b.csv?acl=public-read"}, {key: "inbox/c%41 d.csv"}]
          }
        )
        client
      end

      describe "a url part or argument that the path cannot use, which v3.0 raises ArgumentError for" do
        it "reports a deprecation warning for a fragment, which an unencoded '#' starts, and still reads the key before it" do
          line = __LINE__ + 2
          path = assert_deprecated(%r{s3_test\.rb:#{line}: warning: IOStreams: the S3 url "s3://bucket/a" is deprecated, since it has a fragment, which a '#' starts, and which is not part of the key, percent-encode a '#' in a key as '%23'\n\z}) do
            IOStreams.path("s3://bucket/a#b.csv")
          end

          assert_equal "a", path.path
          assert_equal "a#b.csv", refute_deprecated { IOStreams.path("s3://bucket/a%23b.csv") }.path
        end

        it "reports a deprecation warning for a port, which is ignored" do
          path = assert_deprecated(%r{IOStreams: the S3 url "s3://bucket/a\.csv" is deprecated, since its port is ignored, supply the endpoint of another service that implements the S3 API with client: \{endpoint: "https://host:port"\}\n\z}) do
            IOStreams.path("s3://bucket:9000/a.csv")
          end

          assert_equal "s3://bucket/a.csv", path.to_s
        end

        it "reports a deprecation warning for a user name or password, which are ignored, without them" do
          path = assert_deprecated(%r{IOStreams: the S3 url "s3://bucket/a\.csv" is deprecated, since its user name and password are ignored, supply the credentials with access_key_id: and secret_access_key:\n\z}) do
            IOStreams.path("s3://AKIA:TOP-SECRET@bucket/a.csv")
          end

          assert_equal "s3://bucket/a.csv", path.to_s
          assert_deprecated(/its user name and password are ignored/) { IOStreams.path("s3://AKIA@bucket/a.csv") }
        end

        it "reports a deprecation warning for a url without a bucket" do
          path = assert_deprecated(%r{IOStreams: the S3 url "s3:///a\.csv" is deprecated, since it names no bucket, name one, such as 's3://bucket/a\.csv'\n\z}) do
            IOStreams.path("s3:///a.csv")
          end

          assert_equal "s3://a.csv", path.to_s
        end

        it "reports each part that the path cannot use" do
          assert_deprecated(/has a fragment/, /its port is ignored/, /its user name and password are ignored/) do
            IOStreams.path("s3://AKIA:TOP-SECRET@bucket:9000/a#b.csv")
          end
        end

        it "reports a deprecation warning for the region and credentials supplied with an Aws::S3::Client, which ignores them" do
          line = __LINE__ + 2
          path = assert_deprecated(/s3_test\.rb:#{line}: warning: IOStreams: access_key_id:, secret_access_key:, region: are deprecated with an Aws::S3::Client as client:, which ignores them, since it has its own, supply them to Aws::S3::Client\.new instead, or supply client: as a Hash of its options\n\z/) do
            IOStreams.path("s3://bucket/a.csv", client: client, access_key_id: "a", secret_access_key: "b", region: "eu-west-1")
          end

          assert_same client, path.client
          assert_deprecated(/region: is deprecated with an Aws::S3::Client as client:, which ignores it/) do
            IOStreams.path("s3://bucket/a.csv", client: client, region: "eu-west-1")
          end
        end

        it "reports no deprecation warning for the region and credentials supplied with the options of a new client" do
          path = refute_deprecated do
            IOStreams.path("s3://bucket/a.csv", client: {stub_responses: true}, access_key_id: "a", secret_access_key: "b",
                                                region: "eu-west-1")
          end

          assert_equal "eu-west-1", path.client.config.region
        end

        it "reports no deprecation warning for a url that the path can use" do
          refute_deprecated do
            IOStreams.path("s3://bucket/data/a%23b.csv", client: client)
            IOStreams.path("s3://bucket", client: client)
          end
        end

        it "checks nothing while deprecation warnings are off, since each child that #each_child yields is a new path" do
          enabled = Warning[:deprecated]
          Warning[:deprecated] = false
          checked = ->(*) { flunk("checked while deprecation warnings are off") }
          path    = IOStreams::Paths::S3.stub(:known_option_names, checked) do
            IOStreams::Utils.stub(:display_text, checked) do
              IOStreams.path("s3://bucket:9000/a?tagging=a#b.csv", client: client, acll: "public-read", region: "eu-west-1")
            end
          end

          assert_equal "a", path.path
          assert_equal({acll: "public-read", tagging: "a"}, path.options)
        ensure
          Warning[:deprecated] = enabled
        end
      end

      describe "an option that no S3 request takes, or that the path sets itself, which v3.0 raises ArgumentError for" do
        it "reports a deprecation warning for an option that no S3 request takes, and keeps it as before" do
          line = __LINE__ + 2
          path = assert_deprecated(/s3_test\.rb:#{line}: warning: IOStreams: the S3 option acll: is deprecated, since no S3 request takes it, so correct or remove it\n\z/) do
            IOStreams.path("s3://bucket/a.csv", client: client, acll: "public-read")
          end

          assert_equal({acll: "public-read"}, path.options)
        end

        it "reports a deprecation warning for an option that the path sets itself, which it overrides" do
          path = assert_deprecated(/IOStreams: the S3 options key:, bucket: are deprecated, since the path sets them itself, and overrides them, so remove them\n\z/) do
            IOStreams.path("s3://bucket/a.csv", client: client, key: "b.csv", bucket: "other")
          end

          assert_equal "a.csv", path.path
          assert_equal "bucket", path.bucket_name
        end

        it "reports a deprecation warning for an option named with a String, which the AWS SDK does not take" do
          assert_deprecated(/IOStreams: the S3 option "acl" is deprecated, since no S3 request takes it/) do
            IOStreams.path("s3://bucket/a.csv", client: client, **{"acl" => "public-read"})
          end
        end

        it "reports a deprecation warning for a name in the query of the url that no S3 request takes" do
          path = assert_deprecated(%r{IOStreams: "acll" in the query of the S3 url "s3://bucket/a\.csv" is deprecated, since no S3 request takes it, so correct or remove it\n\z}) do
            IOStreams.path("s3://bucket/a.csv?acll=public-read", client: client)
          end

          assert_equal({acll: "public-read"}, path.options)
          assert_deprecated(%r{"key" in the query of the S3 url "s3://bucket/a\.csv" is deprecated, since the path sets it itself}) do
            IOStreams.path("s3://bucket/a.csv?key=b.csv", client: client)
          end
        end

        it "says how to write a '?' in a key, for a name in the query without a value" do
          path = assert_deprecated(%r{IOStreams: "\.csv" in the query of the S3 url "s3://bucket/data/file" is deprecated, since no S3 request takes it, so correct or remove it, and percent-encode a '\?' in a key as '%3F'\n\z}) do
            IOStreams.path("s3://bucket/data/file?.csv", client: client)
          end

          assert_equal "data/file", path.path
          assert_equal "data/file?.csv", refute_deprecated { IOStreams.path("s3://bucket/data/file%3F.csv", client: client) }.path
        end

        it "reports no deprecation warning for the options of S3 requests, as options or in the query of the url" do
          path = refute_deprecated do
            IOStreams.path("s3://bucket/a.csv?request_payer=requester", client: client, acl: "bucket-owner-full-control",
                                                                         server_side_encryption: "AES256", max_keys: 5)
          end

          assert_equal({acl: "bucket-owner-full-control", server_side_encryption: "AES256", max_keys: 5, request_payer: "requester"},
                       path.options)
          refute_deprecated { IOStreams.path("s3://bucket/a.csv?", client: client) }
        end
      end

      describe "#join" do
        it "joins a name that only shares a prefix with the key" do
          path = IOStreams::Paths::S3.new("s3://bucket/reports", client: client)

          assert_equal "s3://bucket/reports/reports_2024.csv", path.join("reports_2024.csv").to_s
        end

        it "joins a name onto the bucket root" do
          path = IOStreams::Paths::S3.new("s3://bucket", client: client)

          assert_equal "reports/2024.csv", path.join("reports/2024.csv").path
        end
      end

      describe "#each_child" do
        it "does not parse object keys as part of a url" do
          path     = IOStreams::Paths::S3.new("s3://bucket/inbox", client: client)
          children = path.each_child("**/*").to_a.map(&:first)

          assert_equal ["inbox/a+b.csv?acl=public-read", "inbox/c%41 d.csv"], children.map(&:path)
          children.each do |child|
            assert_instance_of IOStreams::Paths::S3, child
            assert_equal "bucket", child.bucket_name
            assert_empty child.options
          end
        end

        it "uses the same client for the children" do
          path     = IOStreams::Paths::S3.new("s3://bucket/inbox", client: client)
          children = path.each_child("**/*").to_a.map(&:first)

          children.each { |child| assert_same client, child.client }
        end

        it "uses the same client options for the children" do
          path = IOStreams::Paths::S3.new("s3://bucket/inbox", client: {stub_responses: true}, region: "eu-west-1")
          path.client.stub_responses(:list_objects_v2, {name: "bucket", contents: [{key: "inbox/a.csv"}]})
          children = path.each_child("**/*").to_a.map(&:first)

          assert_equal ["inbox/a.csv"], children.map(&:path)
          assert_equal "eu-west-1", children.first.client.config.region
        end
      end
    end
  end
end
