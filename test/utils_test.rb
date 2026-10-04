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

      it "does not run the block again when it raises Errno::EEXIST" do
        count = 0
        assert_raises Errno::EEXIST do
          IOStreams::Utils.temp_file_name("base", ".ext") do |_file_name|
            count += 1
            raise(Errno::EEXIST, "from the block")
          end
        end

        assert_equal 1, count
      end

      it "deletes the file when the block raises" do
        name = nil
        assert_raises ArgumentError do
          IOStreams::Utils.temp_file_name("base", ".ext") do |file_name|
            name = file_name
            File.write(file_name, "data")
            raise(ArgumentError, "failed")
          end
        end

        refute_path_exists name
      end

      it "uses another name when the file name already exists, and leaves the existing file" do
        existing = File.join(IOStreams.temp_dir, "base#{Time.now.strftime('%Y%m%d')}-#{$$}-0.ext")
        File.write(existing, "existing")
        name = Random.stub(:urandom, "\0\0\0\0".b) do
          IOStreams::Utils.temp_file_name("base", ".ext") { |file_name| file_name }
        end

        refute_equal existing, name
        assert_equal "existing", File.read(existing)
      ensure
        FileUtils.rm_f(existing)
      end
    end

    describe ".private_temp_file" do
      it "yields an empty file that only the current user can read" do
        IOStreams::Utils.private_temp_file("base", ".ext") do |file_name|
          assert_equal 0, File.size(file_name)
          assert_equal 0o600, File.stat(file_name).mode & 0o777
        end
      end

      it "keeps the permissions when the file is written to" do
        IOStreams::Utils.private_temp_file("base", ".ext") do |file_name|
          File.binwrite(file_name, "secret")

          assert_equal "secret", File.read(file_name)
          assert_equal 0o600, File.stat(file_name).mode & 0o777
        end
      end

      it "returns the value from the block" do
        assert_equal 257, IOStreams::Utils.private_temp_file("base", ".ext") { |_file_name| 257 }
      end

      it "deletes the file afterwards" do
        name = IOStreams::Utils.private_temp_file("base", ".ext") { |file_name| file_name }

        refute_path_exists name
      end

      it "deletes the file when the block raises" do
        name = nil
        assert_raises ArgumentError do
          IOStreams::Utils.private_temp_file("base", ".ext") do |file_name|
            name = file_name
            raise(ArgumentError, "failed")
          end
        end

        refute_path_exists name
      end

      describe "when the file name already exists" do
        # Dir::Tmpname adds a random value from `Random.urandom` to each name; fixing it at 0 makes the name predictable.
        let(:random_bytes) { "\0\0\0\0".b }
        let(:existing) { File.join(IOStreams.temp_dir, "base#{Time.now.strftime('%Y%m%d')}-#{$$}-0.ext") }

        after do
          FileUtils.rm_f(existing)
        end

        it "uses another name and leaves the existing file" do
          File.write(existing, "existing")
          name = Random.stub(:urandom, random_bytes) do
            IOStreams::Utils.private_temp_file("base", ".ext") { |file_name| file_name }
          end

          refute_equal existing, name
          assert_equal "existing", File.read(existing)
        end

        it "does not follow a link planted at the file name" do
          IOStreams::Utils.private_temp_file("target", ".ext") do |target|
            File.symlink(target, existing)
            Random.stub(:urandom, random_bytes) do
              IOStreams::Utils.private_temp_file("base", ".ext") { |file_name| File.write(file_name, "secret") }
            end

            assert_equal "", File.read(target)
            assert File.symlink?(existing)
          end
        end
      end

      it "does not run the block again when it raises Errno::EEXIST" do
        count = 0
        assert_raises Errno::EEXIST do
          IOStreams::Utils.private_temp_file("base", ".ext") do |_file_name|
            count += 1
            raise(Errno::EEXIST, "from the block")
          end
        end

        assert_equal 1, count
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

      it "keeps a plus sign in the path" do
        uri = IOStreams::Utils::URI.new("s3://bucket/a+b/c%2Bd.csv")

        assert_equal "/a+b/c+d.csv", uri.path
      end
    end
  end
end
