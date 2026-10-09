require_relative "test_helper"
require "logger"

class UtilsTest < Minitest::Test
  describe IOStreams::Utils do
    describe ".redact_options" do
      it "replaces the declared options, and those that are sensitive by name" do
        options = {region: "east", license: "a", db_password: "b", session_token: "c", aws_credentials: "d"}

        assert_equal({region: "east", license: "[FILTERED]", db_password: "[FILTERED]", session_token: "[FILTERED]",
                      aws_credentials: "[FILTERED]"},
                     IOStreams::Utils.redact_options(options, %i[license]))
      end

      it "replaces authentication, API key and private key options by name" do
        options = {"Authorization" => "a", "X-Auth-Token" => "b", "X-Api-Key" => "c", private_key: "d", "Accept" => "text/csv"}

        assert_equal({"Authorization" => "[FILTERED]", "X-Auth-Token" => "[FILTERED]", "X-Api-Key" => "[FILTERED]",
                      private_key: "[FILTERED]", "Accept" => "text/csv"},
                     IOStreams::Utils.redact_options(options))
      end

      it "matches names in any case, with or without _ and -" do
        options = {"IdentityKey" => "a", "Proxy-Authorization" => "b", "Accept" => "text/csv"}

        assert_equal({"IdentityKey" => "[FILTERED]", "Proxy-Authorization" => "[FILTERED]", "Accept" => "text/csv"},
                     IOStreams::Utils.redact_options(options, %i[identity_key proxy_authorization]))
      end

      it "redacts the options within a Hash" do
        options = {client: {region: "east", secret_access_key: "a"}}

        assert_equal({client: {region: "east", secret_access_key: "[FILTERED]"}}, IOStreams::Utils.redact_options(options))
      end

      it "redacts the options within an Array of Hashes or of name and value pairs" do
        options = {clients: [{region: "east", password: "a"}], headers: [["Authorization", "b"], ["Accept", "text/csv"]]}

        assert_equal({clients: [{region: "east", password: "[FILTERED]"}],
                      headers: [["Authorization", "[FILTERED]"], ["Accept", "text/csv"]]},
                     IOStreams::Utils.redact_options(options))
      end

      it "keeps the values of an Array that are not options" do
        assert_equal({hosts: %w[a b], ports: [[1, 2]]}, IOStreams::Utils.redact_options(hosts: %w[a b], ports: [[1, 2]]))
      end

      it "does not change the options" do
        options = {password: "a"}
        IOStreams::Utils.redact_options(options)

        assert_equal({password: "a"}, options)
      end
    end

    describe ".matchable" do
      it "returns a string that is valid in its encoding" do
        name = "café.csv"

        assert_same name, IOStreams::Utils.matchable(name)
      end

      it "returns the bytes of a string that is not valid in its encoding" do
        name = "caf\xE9.csv".dup.force_encoding(Encoding::UTF_8)

        assert_equal "caf\xE9.csv".b, IOStreams::Utils.matchable(name)
        assert_equal Encoding::BINARY, IOStreams::Utils.matchable(name).encoding
      end
    end

    describe ".display_text" do
      it "returns valid UTF-8 as it is" do
        assert_equal "/data/café.csv", IOStreams::Utils.display_text("/data/café.csv")
      end

      it "reads a binary string as UTF-8" do
        text = IOStreams::Utils.display_text("/data/café.csv".b)

        assert_equal "/data/café.csv", text
        assert_equal Encoding::UTF_8, text.encoding
      end

      it "shows each byte that is not valid UTF-8 as \\xHH" do
        assert_equal "/data/caf\\xE9.csv", IOStreams::Utils.display_text("/data/caf\xE9.csv".dup.force_encoding(Encoding::UTF_8))
        assert_equal "/data/caf\\xE9.csv", IOStreams::Utils.display_text("/data/caf\xE9.csv".b)
      end
    end

    describe ".file_name_extensions" do
      it "returns the extensions of a name that is not valid UTF-8" do
        assert_equal %w[csv gz], IOStreams::Utils.file_name_extensions("caf\xE9.CSV.gz".dup.force_encoding(Encoding::UTF_8))
      end
    end

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
        IOStreams::Utils.private_temp_file("base", ".ext", purpose: "a test") do |file_name|
          assert_equal 0, File.size(file_name)
          assert_equal 0o600, File.stat(file_name).mode & 0o777
        end
      end

      it "keeps the permissions when the file is written to" do
        IOStreams::Utils.private_temp_file("base", ".ext", purpose: "a test") do |file_name|
          File.binwrite(file_name, "secret")

          assert_equal "secret", File.read(file_name)
          assert_equal 0o600, File.stat(file_name).mode & 0o777
        end
      end

      it "returns the value from the block" do
        assert_equal 257, IOStreams::Utils.private_temp_file("base", ".ext", purpose: "a test") { |_file_name| 257 }
      end

      it "deletes the file afterwards" do
        name = IOStreams::Utils.private_temp_file("base", ".ext", purpose: "a test") { |file_name| file_name }

        refute_path_exists name
      end

      it "deletes the file when the block raises" do
        name = nil
        assert_raises ArgumentError do
          IOStreams::Utils.private_temp_file("base", ".ext", purpose: "a test") do |file_name|
            name = file_name
            raise(ArgumentError, "failed")
          end
        end

        refute_path_exists name
      end

      it "logs the file at debug level, with what it holds when it is created, and its size when it is deleted" do
        output   = StringIO.new
        original = IOStreams.logger
        IOStreams.logger = Logger.new(output, level: :debug)
        name = IOStreams::Utils.private_temp_file("base", ".ext", purpose: "the download of a.csv") do |file_name|
          File.write(file_name, "a,b\n")
          file_name
        end

        assert_includes output.string, "Created temp file #{name} for the download of a.csv"
        assert_includes output.string, "Deleting temp file #{name}, which held 4 bytes"
      ensure
        IOStreams.logger = original
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
            IOStreams::Utils.private_temp_file("base", ".ext", purpose: "a test") { |file_name| file_name }
          end

          refute_equal existing, name
          assert_equal "existing", File.read(existing)
        end

        it "does not follow a link planted at the file name" do
          IOStreams::Utils.private_temp_file("target", ".ext", purpose: "a test") do |target|
            File.symlink(target, existing)
            Random.stub(:urandom, random_bytes) do
              IOStreams::Utils.private_temp_file("base", ".ext", purpose: "a test") { |file_name| File.write(file_name, "secret") }
            end

            assert_equal "", File.read(target)
            assert File.symlink?(existing)
          end
        end
      end

      it "does not run the block again when it raises Errno::EEXIST" do
        count = 0
        assert_raises Errno::EEXIST do
          IOStreams::Utils.private_temp_file("base", ".ext", purpose: "a test") do |_file_name|
            count += 1
            raise(Errno::EEXIST, "from the block")
          end
        end

        assert_equal 1, count
      end
    end

    describe ".local_file_name" do
      let(:dir) { Dir.mktmpdir("iostreams_local_file_name") }
      let(:file_name) { File.join(dir, "data.csv") }

      before do
        File.write(file_name, "a,b\n")
      end

      after do
        FileUtils.rm_rf(dir)
      end

      it "returns the name of a local file at its start" do
        File.open(file_name, "rb") { |file| assert_equal file_name, IOStreams::Utils.local_file_name(file) }
      end

      it "returns nil for a local file that is not at its start" do
        File.open(file_name, "rb") do |file|
          file.read(1)

          assert_nil IOStreams::Utils.local_file_name(file)
        end
      end

      it "returns the absolute name of a file opened with a relative name, while it still refers to the file" do
        Dir.chdir(dir) do
          File.write("-", "a,b\n")
          File.open("-", "rb") do |file|
            assert_equal File.join(Dir.pwd, "-"), IOStreams::Utils.local_file_name(file)

            Dir.chdir("/") { assert_nil IOStreams::Utils.local_file_name(file) }
          end
        end
      end

      it "returns nil when the name no longer refers to the file" do
        File.open(file_name, "rb") do |file|
          File.rename(file_name, "#{file_name}.moved")

          assert_nil IOStreams::Utils.local_file_name(file)
        end
      end

      it "returns nil for a closed file" do
        file = File.open(file_name, "rb") { |io| io }

        assert_nil IOStreams::Utils.local_file_name(file)
      end

      it "returns nil for a file that is not a regular file" do
        File.open(File::NULL, "rb") { |file| assert_nil IOStreams::Utils.local_file_name(file) }
      end

      it "returns nil for a stream that is not a file" do
        assert_nil IOStreams::Utils.local_file_name(StringIO.new("a,b\n"))

        IO.pipe do |reader, _writer|
          assert_nil IOStreams::Utils.local_file_name(reader)
        end
      end
    end

    describe ".unknown_host?" do
      it "is true for a host name that does not resolve" do
        skip_without_resolution_error

        assert IOStreams::Utils.unknown_host?(resolution_error(Socket::EAI_NONAME))
      end

      it "is false for a temporary failure of name resolution, such as a DNS outage" do
        skip_without_resolution_error

        refute IOStreams::Utils.unknown_host?(resolution_error(Socket::EAI_AGAIN))
      end

      it "is false for a SocketError that is not a failure of name resolution, as on Ruby 3.2" do
        refute IOStreams::Utils.unknown_host?(SocketError.new("getaddrinfo: nodename nor servname provided"))
      end

      it "is false for any other exception, or nil" do
        refute IOStreams::Utils.unknown_host?(Errno::ECONNREFUSED.new)
        refute IOStreams::Utils.unknown_host?(nil)
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

      it "keeps characters that are not ASCII in the path" do
        uri = IOStreams::Utils::URI.new("s3://bucket/données/café.csv")

        assert_equal "bucket", uri.hostname
        assert_equal "/données/café.csv", uri.path
        assert_equal Encoding::UTF_8, uri.path.encoding
      end

      it "keeps the bytes of a name that is not valid UTF-8" do
        uri = IOStreams::Utils::URI.new("sftp://example.org/in/caf\xE9.csv".dup.force_encoding(Encoding::UTF_8))

        assert_equal "/in/caf\xE9.csv".b, uri.path.b
      end

      it "decodes characters that are not ASCII in the query" do
        uri = IOStreams::Utils::URI.new("s3://bucket/key?prefix=café")

        assert_equal({"prefix" => "café"}, uri.query)
      end

      it "keeps characters in the path that a url cannot hold, such as brackets" do
        name = %(/report [1] {a|b} "x" <y> c^d`e\\f.csv)

        assert_equal name, IOStreams::Utils::URI.new("s3://bucket#{name}").path
      end

      it "parses a host that is an IPv6 address" do
        uri = IOStreams::Utils::URI.new("sftp://[::1]:2222/data/[1].csv")

        assert_equal "::1", uri.hostname
        assert_equal 2222, uri.port
        assert_equal "/data/[1].csv", uri.path
      end
    end
  end
end
