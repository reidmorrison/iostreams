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
          target.copy_from(source, convert: false)

          assert_equal "Hello World", target.read
        end

        it "raises for options that a direct copy cannot use" do
          error = assert_raises(ArgumentError) { target.copy_from(source, convert: false, columns: %w[a]) }
          assert_equal ":columns cannot be used with `convert: false`, which copies the data as-is", error.message
          assert_raises(ArgumentError) { source.copy_to(target, convert: false, mode: :hash) }
          refute_predicate target, :exist?
        end

        it "copies a key that needs url-encoding with copy_to" do
          source.copy_to(target, convert: false)

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
      end
    end
  end
end
