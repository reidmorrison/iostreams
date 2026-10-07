require_relative "../test_helper"
require_relative "../s3_stub"

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
      end

      describe "#size" do
        it "existing file" do
          assert_equal raw.size, existing_path.size
        end

        it "missing file" do
          assert_nil missing_path.size
        end
      end

      describe "file and directory predicates" do
        let(:dir) { root_path.join("predicates_test") }
        let(:keys) { %w[a/data.txt a/empty.txt folder/] }

        before do
          dir.join("a/data.txt").write(raw)
          dir.join("a/empty.txt").write("")
          # An empty folder, as created by the S3 console.
          dir.client.put_object(bucket: dir.bucket_name, key: "#{dir.path}/folder/", body: "")
        end

        after do
          keys.each { |key| dir.client.delete_object(bucket: dir.bucket_name, key: "#{dir.path}/#{key}") }
        end

        it "#file? is true for an object" do
          assert_predicate dir.join("a/data.txt"), :file?
          refute_predicate dir.join("a"), :file?
          refute_predicate dir.join("folder"), :file?
          refute_predicate dir.join("a/missing.txt"), :file?
        end

        it "#directory? is true for a path within a key, or a folder object" do
          assert_predicate dir, :directory?
          assert_predicate dir.join("a"), :directory?
          assert_predicate dir.join("folder"), :directory?
          assert_predicate IOStreams::Paths::S3.new("s3://#{dir.bucket_name}"), :directory?
          refute_predicate dir.join("a/data.txt"), :directory?
          refute_predicate dir.join("missing"), :directory?
        end

        it "#empty? is true for an empty object or folder" do
          assert_predicate dir.join("a/empty.txt"), :empty?
          assert_predicate dir.join("folder"), :empty?
          refute_predicate dir.join("a/data.txt"), :empty?
          refute_predicate dir.join("a"), :empty?
          refute_predicate dir.join("missing"), :empty?
        end

        it "#size? returns the size of an object with data" do
          assert_equal raw.size, dir.join("a/data.txt").size?
          assert_nil dir.join("a/empty.txt").size?
          assert_nil dir.join("a/missing.txt").size?
        end
      end

      describe "#writer" do
        it "writes" do
          assert_equal(raw.size, write_path.writer { |io| io.write(raw) })
          assert_predicate write_path, :exist?
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

        it "returns the directories within the keys" do
          write_raw_data

          assert_equal %w[abd xyz].collect { |name| each_root.join(name).to_s },
                       each_root.children(directories: true).collect(&:to_s).sort
          assert_equal (%w[abd abd/extra xyz] + files_for_test).collect { |name| each_root.join(name).to_s }.sort,
                       each_root.children("**/*", directories: true).collect(&:to_s).sort
        end

        it "returns an empty folder as a directory" do
          folder = each_root.join("empty_folder")
          folder.client.put_object(bucket: folder.bucket_name, key: "#{folder.path}/", body: "")

          assert_includes each_root.children(directories: true).collect(&:to_s), folder.to_s
          refute_includes each_root.children("**/*").collect(&:to_s), "#{folder}/"
        ensure
          folder.client.delete_object(bucket: folder.bucket_name, key: "#{folder.path}/")
        end

        it "yields the attributes of an exact name" do
          write_raw_data
          children = each_root.each_child("abd/test1.txt").to_a

          assert_equal([each_root.join("abd/test1.txt").to_s], children.collect { |child, _| child.to_s })
          assert_equal raw.bytesize, children.first.last[:size]
        end

        it "returns an exact directory name only when requested" do
          write_raw_data

          assert_empty each_root.children("abd")
          assert_equal [each_root.join("abd").to_s], each_root.children("abd", directories: true).collect(&:to_s)
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

        it "moves to a local file" do
          source = root_path.join("move_test_source.txt")
          Dir.mktmpdir do |dir|
            source.write("Hello World")
            target = IOStreams.path(dir, "move_test_target.txt")

            assert_equal target, source.move_to(target)
            assert_equal "Hello World", target.read
            refute_predicate source, :exist?
          end
        ensure
          source&.delete
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

      describe "direct copies" do
        let(:source) { root_path.join("copy test a+b %41 ?.txt") }
        let(:target) { root_path.join("copy test target a+b %41 ?.txt") }

        before { source.write("Hello World") }

        after do
          source.delete
          target.delete
        end

        it "copies a key that needs url-encoding with copy_from" do
          assert_equal 11, target.copy_from(source, convert: false)

          assert_equal "Hello World", target.read
        end

        it "raises for options that a direct copy cannot use" do
          error = assert_raises(ArgumentError) { target.copy_from(source, convert: false, columns: %w[a]) }
          assert_equal ":columns cannot be used with `convert: false`, which copies the data as-is", error.message
          assert_raises(ArgumentError) { source.copy_to(target, convert: false, mode: :hash) }
          refute_predicate target, :exist?
        end

        it "copies a key that needs url-encoding with copy_to" do
          assert_equal 11, source.copy_to(target, convert: false)

          assert_equal "Hello World", target.read
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

      describe "#initialize" do
        it "keeps a plus sign in the key" do
          path = IOStreams::Paths::S3.new("s3://bucket/reports/a+b.csv", client: client)

          assert_equal "reports/a+b.csv", path.path
        end
      end

      describe "options" do
        # Returns the parameters of each request the client received.
        def capture_requests(client)
          requests = Hash.new { |hash, key| hash[key] = [] }
          client.handlers.add(Class.new(Seahorse::Client::Handler) do
            define_method(:call) do |context|
              requests[context.operation_name] << context.params
              @handler.call(context)
            end
          end, step: :initialize)
          requests
        end

        it "reads a path with a writer option, such as acl" do
          client.stub_responses(:get_object, {body: "data"})
          path = IOStreams::Paths::S3.new("s3://bucket/a.txt?acl=public-read", client: client)
          requests = capture_requests(client)

          assert_equal "data", path.read
          refute requests[:get_object].first.key?(:acl)
        end

        it "writes with a writer option" do
          path = IOStreams::Paths::S3.new("s3://bucket/a.txt", client: client, acl: "bucket-owner-full-control")
          requests = capture_requests(client)
          path.write("data")

          assert_equal "bucket-owner-full-control", requests[:put_object].first[:acl]
        end

        it "supplies an option to every request that accepts it" do
          client.stub_responses(:head_object, {content_length: 4})
          client.stub_responses(:get_object, {body: "data"})
          path = IOStreams::Paths::S3.new("s3://bucket/a.txt", client: client, request_payer: "requester")
          requests = capture_requests(client)
          path.size
          path.exist?
          path.read
          path.write("data")
          path.delete
          path.directory.each_child { |child| child }

          %i[head_object get_object put_object delete_object list_objects_v2].each do |operation|
            assert_equal ["requester"], requests[operation].map { |params| params[:request_payer] }.uniq, operation
          end
        end

        it "raises for an option that no request accepts" do
          error = assert_raises(ArgumentError) { IOStreams::Paths::S3.new("s3://bucket/a.txt", client: client, acll: "public-read") }
          assert_equal "Unknown S3 option: :acll", error.message
          assert_raises(ArgumentError) { IOStreams.path("s3://bucket/a.txt?bogus=1&key=b") }
        end

        it "raises for a request parameter that the path sets" do
          assert_raises(ArgumentError) { IOStreams::Paths::S3.new("s3://bucket/a.txt", client: client, bucket: "other") }
        end
      end

      describe "#absolute?" do
        it "is always true" do
          %w[s3://bucket s3://bucket/a.csv s3://bucket/a/b.csv].each do |url|
            path = IOStreams::Paths::S3.new(url, client: client)

            assert_predicate path, :absolute?, url
            refute_predicate path, :relative?, url
          end
        end
      end

      describe "#directory" do
        it "returns the directory of the key" do
          path = IOStreams::Paths::S3.new("s3://bucket/a/b/c.csv", client: client)

          assert_equal "s3://bucket/a/b", path.directory.to_s
        end

        it "returns the bucket for a key without a directory" do
          %w[s3://bucket/a.csv s3://bucket/a/ s3://bucket].each do |url|
            directory = IOStreams::Paths::S3.new(url, client: client).directory

            assert_equal "", directory.path, url
            assert_equal "s3://bucket/", directory.to_s, url
            assert_equal "b.csv", directory.join("b.csv").path, url
          end
        end
      end

      describe "#join" do
        it "shares the client with the joined path" do
          path   = IOStreams::Paths::S3.new("s3://bucket/data", client: {stub_responses: true}, region: "eu-west-1").freeze
          joined = path.join("a.csv")

          assert_same path.client, joined.client
        end

        it "shares a client created by the joined path" do
          path   = IOStreams::Paths::S3.new("s3://bucket/data", client: {stub_responses: true}, region: "eu-west-1")
          joined = path.join("a.csv")

          assert_same joined.client, path.client
        end

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

        it "lists the children of a frozen path" do
          path = IOStreams::Paths::S3.new("s3://bucket/inbox", client: {stub_responses: true}, region: "eu-west-1").freeze
          path.client.stub_responses(:list_objects_v2, {name: "bucket", contents: [{key: "inbox/a.csv"}]})

          assert_equal ["s3://bucket/inbox/a.csv"], path.children("*.csv").map(&:to_s)
          assert_same path.client, path.client
        end

        it "uses the same client options for the children" do
          path = IOStreams::Paths::S3.new("s3://bucket/inbox", client: {stub_responses: true}, region: "eu-west-1")
          path.client.stub_responses(:list_objects_v2, {name: "bucket", contents: [{key: "inbox/a.csv"}]})
          children = path.each_child("**/*").to_a.map(&:first)

          assert_equal ["inbox/a.csv"], children.map(&:path)
          assert_equal "eu-west-1", children.first.client.config.region
        end

        describe "with objects in the bucket" do
          before do
            IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
            S3Stub.install
            ["reports/a.csv", "reports/2024/b.csv", "reports_x.csv", "reports_2024/c.csv", "reports.csv", "dir a+b/d.csv", "100%/e.csv"].
              each { |key| IOStreams.path("s3://bucket").join(key).write("data") }
          end

          after do
            S3Stub.uninstall
          end

          it "only returns children within the path" do
            children = IOStreams.path("s3://bucket/reports").children("*.csv", hidden: true).map(&:to_s)

            assert_equal ["s3://bucket/reports/a.csv"], children
          end

          it "matches a pattern within the path even when it starts with the name of the path" do
            IOStreams.path("s3://bucket/reports/reports/inner.csv").write("data")
            children = IOStreams.path("s3://bucket/reports").children("reports/*.csv").map(&:to_s)

            assert_equal ["s3://bucket/reports/reports/inner.csv"], children
          end

          it "treats a backslash as escaping the next character, like local paths" do
            children = IOStreams.path("s3://bucket/reports").children("\\a.csv").map(&:to_s)

            assert_equal ["s3://bucket/reports/a.csv"], children
          end

          it "only returns children within the path when the pattern is recursive" do
            children = IOStreams.path("s3://bucket/reports").children("**/*.csv").map(&:to_s)

            assert_equal ["s3://bucket/reports/2024/b.csv", "s3://bucket/reports/a.csv"], children.sort
          end

          it "lists a key that contains characters a url parser would decode" do
            children = IOStreams.path("s3://bucket").join("dir a+b").children("*.csv").map(&:path)

            assert_equal ["dir a+b/d.csv"], children
          end

          it "lists a key that contains a percent sign" do
            children = IOStreams.path("s3://bucket").join("100%").children("*.csv").map(&:path)

            assert_equal ["100%/e.csv"], children
          end

          it "lists the whole bucket" do
            assert_includes IOStreams.path("s3://bucket").children("*.csv").map(&:path), "reports_x.csv"
          end

          it "uses the same options for the children" do
            children = IOStreams.path("s3://bucket/reports", request_payer: "requester").children("*.csv")

            assert_equal [{request_payer: "requester"}], children.map(&:options)
          end
        end
      end

      describe "#copy_from" do
        before do
          IOStreams::Utils.load_soft_dependency("aws-sdk-s3", "AWS S3")
          S3Stub.install
          IOStreams.path("s3://bucket/reports/a.csv").write("data")
        end

        after do
          S3Stub.uninstall
        end

        it "keeps an existing object when the copy fails" do
          target = IOStreams.path("s3://bucket/reports/a.csv")

          assert_raises(Errno::ENOENT) { target.copy_from("/does/not/exist.csv") }
          assert_equal "data", target.read
        end

        it "keeps an existing object when the copy fails part way" do
          target         = IOStreams.path("s3://bucket/reports/a.csv")
          failing_source = Object.new
          def failing_source.read(*)
            raise(IOError, "failed part way")
          end

          assert_raises(IOError) { target.copy_from(failing_source) }
          assert_equal "data", target.read
        end

        it "uploads without a head request" do
          target = IOStreams.path("s3://bucket/reports/new.csv")

          target.copy_from(StringIO.new("new data"))

          assert_equal([:put_object], target.client.api_requests.map { |request| request[:operation_name] })
          assert_equal "new data", target.read
        end

        it "does not delete a new object when the copy fails" do
          target         = IOStreams.path("s3://bucket/reports/new.csv")
          failing_source = Object.new
          def failing_source.read(*)
            raise(IOError, "failed part way")
          end

          assert_raises(IOError) { target.copy_from(failing_source) }
          assert_empty(target.client.api_requests.map { |request| request[:operation_name] })
        end
      end
    end
  end
end
