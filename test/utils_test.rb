require_relative "test_helper"

class UtilsTest < Minitest::Test
  describe IOStreams::Utils do
    describe ".temp_file_name" do
      it "returns value from block" do
        result = IOStreams::Utils.temp_file_name("base", ".ext") { |_name| 257 }

        assert_equal 257, result
      end

      it "supplies new temp file_name" do
        file_name  = nil
        file_name2 = nil
        IOStreams::Utils.temp_file_name("base", ".ext") { |name| file_name = name }
        IOStreams::Utils.temp_file_name("base", ".ext") { |name| file_name2 = name }

        refute_equal file_name, file_name2
      end
    end

    describe ".load_soft_dependency" do
      it "raises a helpful error when the gem cannot be loaded" do
        error = assert_raises LoadError do
          IOStreams::Utils.load_soft_dependency("no_such_gem", "Testing", "no_such_gem_require")
        end
        assert_includes error.message, "no_such_gem"
        assert_includes error.message, "Testing"
      end
    end

    describe IOStreams::Utils::URI do
      it "parses the scheme, hostname and path" do
        uri = IOStreams::Utils::URI.new("https://example.org/path/file.txt")

        assert_equal "https", uri.scheme
        assert_equal "example.org", uri.hostname
        assert_equal "/path/file.txt", uri.path
      end

      it "parses the user, password and port" do
        uri = IOStreams::Utils::URI.new("sftp://jack:secret@example.org:2222/dir/file.txt")

        assert_equal "jack", uri.user
        assert_equal "secret", uri.password
        assert_equal 2222, uri.port
      end

      it "decodes the query string into a hash" do
        uri = IOStreams::Utils::URI.new("s3://bucket/key?max_keys=5&prefix=abc")

        assert_equal({"max_keys" => "5", "prefix" => "abc"}, uri.query)
      end

      it "returns a nil query when none is present" do
        uri = IOStreams::Utils::URI.new("https://example.org/file.txt")

        assert_nil uri.query
      end

      it "encodes spaces in the url" do
        uri = IOStreams::Utils::URI.new("https://example.org/a b/c d.txt")

        assert_equal "/a b/c d.txt", uri.path
      end

      it "unescapes a percent-encoded path" do
        uri = IOStreams::Utils::URI.new("https://example.org/a%20b/file.txt")

        assert_equal "/a b/file.txt", uri.path
      end
    end
  end
end
