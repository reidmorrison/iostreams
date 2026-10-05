require_relative "test_helper"

module IOStreams
  class PathTest < Minitest::Test
    describe IOStreams::Path do
      describe ".join" do
        let(:path) { IOStreams::Path.new("some_path") }

        it "returns a copy when no elements" do
          path.stream(:gz)
          copy = path.join
          copy.stream(:enc)

          refute_same path, copy
          assert_equal path, copy
          assert_equal({gz: {}}, path.pipeline)
          assert_equal({gz: {}, enc: {}}, copy.pipeline)
        end

        it "adds element to path" do
          assert_equal ::File.join("some_path", "test"), path.join("test").to_s
        end

        it "adds paths to root" do
          assert_equal ::File.join("some_path", "test", "second", "third"), path.join("test", "second", "third").to_s
        end

        it "returns path and filename" do
          assert_equal ::File.join("some_path", "file.xls"), path.join("file.xls").to_s
        end

        it "adds elements to path" do
          assert_equal ::File.join("some_path", "test", "second", "third", "file.xls"), path.join("test", "second", "third", "file.xls").to_s
        end

        it "return path as sent in when full path" do
          assert_equal ::File.join("some_path", "test", "second", "third", "file.xls"), path.join("some_path", "test", "second", "third", "file.xls").to_s
        end

        it "joins an element that only shares a prefix with the path" do
          assert_equal "some_path/some_path_2024.csv", path.join("some_path_2024.csv").to_s
        end

        it "joins an absolute path that only shares a prefix with the path" do
          root = IOStreams::Path.new("/data/uploads")

          assert_equal "/data/uploads/data/uploads_other/secret.csv", root.join("/data/uploads_other/secret.csv").to_s
        end

        it "returns the path when the element is the path" do
          assert_equal "some_path", path.join("some_path").to_s
        end

        it "returns a full path when the path ends with a slash" do
          root = IOStreams::Path.new("/data/")

          assert_equal "/data/file.csv", root.join("/data/file.csv").to_s
          assert_equal "/data/other.csv", root.join("other.csv").to_s
        end

        it "returns the element when the path is empty" do
          assert_equal "file.csv", IOStreams::Path.new("").join("file.csv").to_s
        end
      end

      describe "#path=" do
        it "is not public" do
          %w[/data/a.csv s3://bucket/a.csv sftp://example.org/a.csv https://example.org/a.csv].each do |name|
            path = IOStreams.path(name)

            assert_raises(NoMethodError, name) { path.path = "b.csv" }
            assert_equal name, path.to_s
          end
        end
      end

      describe "#builder=" do
        it "is not public" do
          path = IOStreams.path("a.csv.gz").stream(:none)

          assert_raises(NoMethodError) { path.builder = nil }
          assert_equal({}, path.pipeline)
        end

        it "is cleared by #join and #directory" do
          path = IOStreams.path("/data/a.csv").stream(:gz)

          assert_equal({gz: {}}, path.pipeline)
          assert_equal({}, path.join("b.csv").pipeline)
          assert_equal({}, path.directory.pipeline)
        end
      end

      describe "a frozen root" do
        %w[/data s3://bucket/data sftp://example.org/data https://example.org/data].each do |name|
          it "can be inspected, joined and compared for #{name}" do
            root = IOStreams.path(name).freeze

            assert_includes root.inspect, "pipeline={}"
            assert_equal "#{name}/a.csv", root.join("a.csv").to_s
            refute_predicate root.join("a.csv"), :frozen?
            assert_equal IOStreams.path(name), root
            assert_equal IOStreams.path(name).directory, root.directory
          end
        end

        it "can list its children" do
          Dir.mktmpdir do |dir|
            ::File.write(::File.join(dir, "a.csv"), "data")
            root = IOStreams.path(dir).freeze

            assert_equal [::File.join(dir, "a.csv")], root.children("*.csv").map(&:to_s)
            assert_predicate root, :exist?
            assert_equal "data", root.join("a.csv").read
          end
        end

        it "explains a change in the error" do
          root  = IOStreams.path("/data").freeze
          error = assert_raises(FrozenError) { root.stream(:gz) }

          assert_includes error.message, "IOStreams::Paths::File:/data"
        end
      end

      describe "#absolute?" do
        it "true on absolute" do
          assert_equal true, IOStreams::Path.new("/a/b/c/d").absolute?
        end

        it "false when not absolute" do
          assert_equal false, IOStreams::Path.new("a/b/c/d").absolute?
        end
      end

      describe "#relatve?" do
        it "true on relative" do
          assert_equal true, IOStreams::Path.new("a/b/c/d").relative?
        end

        it "false on absolute" do
          assert_equal false, IOStreams::Path.new("/a/b/c/d").relative?
        end
      end

      describe "#realpath" do
        it "returns self by default" do
          path = IOStreams::Path.new("a/b/c")

          assert_same path, path.realpath
        end
      end

      describe "#directory" do
        it "returns the parent directory" do
          assert_equal "a/b/d", IOStreams::Path.new("a/b/d/test.rb").directory.to_s
        end

        it "returns '.' when there is no directory" do
          assert_equal ".", IOStreams::Path.new("test.rb").directory.to_s
        end
      end

      describe "#compressed?" do
        it "is true for compressed extensions" do
          %w[file.zip file.gz file.GZIP file.xlsx file.bz2].each do |name|
            assert_predicate IOStreams::Path.new(name), :compressed?, name
          end
        end

        it "is false otherwise" do
          refute_predicate IOStreams::Path.new("file.csv"), :compressed?
        end
      end

      describe "#encrypted?" do
        it "is true for encrypted extensions" do
          %w[file.enc file.pgp file.GPG].each do |name|
            assert_predicate IOStreams::Path.new(name), :encrypted?, name
          end
        end

        it "is false otherwise" do
          refute_predicate IOStreams::Path.new("file.csv"), :encrypted?
        end
      end

      describe "#partial_files_visible?" do
        it "is true by default" do
          assert_predicate IOStreams::Path.new("file.csv"), :partial_files_visible?
        end
      end

      describe "comparison" do
        it "sorts by path name" do
          paths = [IOStreams::Path.new("c"), IOStreams::Path.new("a"), IOStreams::Path.new("b")]

          assert_equal %w[a b c], paths.sort.collect(&:to_s)
        end

        it "is equal when the path matches" do
          assert_equal IOStreams::Path.new("a/b"), IOStreams::Path.new("a/b")
          refute_equal IOStreams::Path.new("a/b"), IOStreams::Path.new("a/c")
        end

        it "is equal to a String of its name" do
          path = IOStreams.path("/home/user/a.txt")

          # The path must be the receiver, since `String#==` is false for anything that is not a String.
          # rubocop:disable Minitest/AssertEqual, Minitest/RefuteEqual
          assert_operator path, :==, "/home/user/a.txt"
          refute_operator path, :==, "/home/user/b.txt"
          refute_operator IOStreams.path("a.txt"), :==, "/home/user/a.txt"
          assert_operator IOStreams.path("s3://bucket/a.txt"), :==, "s3://bucket/a.txt"
          # rubocop:enable Minitest/AssertEqual, Minitest/RefuteEqual
        end

        it "is not equal to anything else" do
          path = IOStreams.path("a.txt")

          refute_equal path, nil
          refute_equal path, 1
          refute_equal path, :"a.txt"
          assert_nil path <=> 1
        end

        it "is not equal to a path in another location with the same name" do
          refute_equal IOStreams.path("s3://bucket-a/reports/x.csv"), IOStreams.path("s3://bucket-b/reports/x.csv")
          refute_equal IOStreams.path("s3://bucket/reports/x.csv"), IOStreams.path("reports/x.csv")
          refute_equal IOStreams.path("sftp://host1/data/x.csv"), IOStreams.path("sftp://host2/data/x.csv")
          refute_equal IOStreams.path("sftp://host/data/x.csv"), IOStreams.path("sftp://host:2222/data/x.csv")
          refute_equal IOStreams.path("https://example.org/x.csv"), IOStreams.path("https://example.com/x.csv")
        end

        it "ignores the streams" do
          assert_equal IOStreams.path("a.csv.gz"), IOStreams.path("a.csv.gz").stream(:none)
        end

        it "is a hash key for its location" do
          paths = [IOStreams.path("a.csv"), IOStreams.path("a.csv"), IOStreams.path("s3://bucket/a.csv")]

          assert_equal 2, paths.uniq.size
          assert_equal 1, {IOStreams.path("a.csv") => 1}[IOStreams.path("a.csv")]
        end

        it "keeps its hash key when joined" do
          %w[/data s3://bucket/data sftp://example.org/data https://example.org/data].each do |name|
            path   = IOStreams.path(name)
            hash   = {path => 1}
            joined = path.join("a.csv")

            assert_equal 1, hash[path], name
            assert_equal "#{name}/a.csv", joined.to_s
          end
        end

        it "sorts paths in different locations" do
          paths = [IOStreams.path("s3://b/x.csv"), IOStreams.path("s3://a/y.csv")]

          assert_equal %w[s3://a/y.csv s3://b/x.csv], paths.sort.map(&:to_s)
        end
      end

      describe "#inspect" do
        it "includes the class name and path" do
          assert_includes IOStreams::Path.new("a/b/file.csv").inspect, "a/b/file.csv"
        end

        it "does not display passphrases set as options" do
          path = IOStreams.path("a/b/file.csv.pgp").option(:pgp, passphrase: "TOP-SECRET")
          str  = path.inspect

          refute_includes str, "TOP-SECRET"
          assert_includes str, "[FILTERED]"
        end

        it "does not display passphrases set as streams" do
          path = IOStreams.path("a/b/file").stream(:pgp, recipient: "a@b.org", signer_passphrase: "TOP-SECRET")
          str  = path.inspect

          refute_includes str, "TOP-SECRET"
          assert_includes str, "a@b.org"
        end
      end

      describe "abstract methods" do
        it "raise NotImplementedError" do
          path = IOStreams::Path.new("a/b/c")

          %i[mkpath mkdir exist? size delete delete_all each_child].each do |method|
            assert_raises(NotImplementedError, method.to_s) { path.public_send(method) }
          end
        end
      end
    end
  end
end
