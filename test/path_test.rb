require_relative "test_helper"

module IOStreams
  class PathTest < Minitest::Test
    describe IOStreams::Path do
      describe ".join" do
        let(:path) { IOStreams::Path.new("some_path") }

        it "returns self when no elements" do
          assert_equal path.object_id, path.join.object_id
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
            assert IOStreams::Path.new(name).compressed?, name
          end
        end

        it "is false otherwise" do
          refute IOStreams::Path.new("file.csv").compressed?
        end
      end

      describe "#encrypted?" do
        it "is true for encrypted extensions" do
          %w[file.enc file.pgp file.GPG].each do |name|
            assert IOStreams::Path.new(name).encrypted?, name
          end
        end

        it "is false otherwise" do
          refute IOStreams::Path.new("file.csv").encrypted?
        end
      end

      describe "#partial_files_visible?" do
        it "is true by default" do
          assert IOStreams::Path.new("file.csv").partial_files_visible?
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
      end

      describe "#inspect" do
        it "includes the class name and path" do
          assert_includes IOStreams::Path.new("a/b/file.csv").inspect, "a/b/file.csv"
        end
      end

      describe "abstract methods" do
        it "raise NotImplementedError" do
          path = IOStreams::Path.new("a/b/c")
          %i[mkpath mkdir exist? size delete delete_all each_child].each do |method|
            assert_raises(NotImplementedError, method) { path.public_send(method) }
          end
        end
      end
    end
  end
end
