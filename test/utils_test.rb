require_relative "test_helper"

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

    describe IOStreams::Utils::PathName do
      # A name in Latin-1, which is not valid UTF-8, in each encoding that it can arrive in: as bytes, such as SFTP lists
      # it, labelled UTF-8, and as Latin-1.
      let(:latin) { "caf\xE9".b }
      let(:latin_names) do
        [latin, latin.dup.force_encoding(Encoding::UTF_8), latin.dup.force_encoding(Encoding::ISO_8859_1)]
      end

      # Returns [Array<String>] every name of up to four of `a`, `/`, `.`, `é` and a byte that is not valid UTF-8, in
      # UTF-8, as bytes, and in Latin-1, with an empty name.
      def names
        tokens = ["a", "/", ".", "\xC3\xA9", "\xE9"]
        names  = [""] + (1..4).flat_map { |size| tokens.repeated_permutation(size).map(&:join) }
        names.uniq.flat_map do |name|
          [name.dup.force_encoding(Encoding::UTF_8), name.b, name.dup.force_encoding(Encoding::ISO_8859_1)]
        end
      end

      # Asserts that the supplied Strings have the same bytes and encoding.
      def assert_same_name(expected, actual, message = nil)
        assert_equal [expected.b, expected.encoding], [actual.b, actual.encoding], message
      end

      it "joins, and finds the directory, extension and last name of, names as CRuby's File does" do
        skip("File changes names that are not valid UTF-8 on this Ruby") unless IOStreams::Utils::PathName::FILE_KEEPS_NAMES

        names.each do |name|
          assert_same_name ::File.dirname(name), IOStreams::Utils::PathName.dirname_of(name), name.inspect
          assert_same_name ::File.extname(name), IOStreams::Utils::PathName.extname_of(name), name.inspect
        end
        short = names.select { |name| name.bytesize <= 2 }
        short.product(short).each do |first, second|
          expected = ::File.join(first, second)

          assert_same_name expected, IOStreams::Utils::PathName.join_names([first, second]), [first, second].inspect
        rescue Encoding::CompatibilityError
          assert_raises(Encoding::CompatibilityError) { IOStreams::Utils::PathName.join_names([first, second]) }
        end

        assert_same_name ::File.join, IOStreams::Utils::PathName.join_names([])
        suffixes = [nil, "", ".*", ".", "a", ".a", "a*", "*", "é", "é*", "\xE9".b]
        names.product(suffixes).each do |name, suffix|
          expected = suffix.nil? ? ::File.basename(name) : ::File.basename(name, suffix)

          assert_same_name expected, IOStreams::Utils::PathName.basename_of(name, suffix), [name, suffix].inspect
        rescue ArgumentError
          assert_raises(ArgumentError) { IOStreams::Utils::PathName.basename_of(name, suffix) }
        end

        assert_same_name ::File.join("a/", "/b", "c"), IOStreams::Utils::PathName.join_names(["a/", "/b", "c"])
      end

      it "keeps the bytes and encoding of a name that is not valid UTF-8" do
        latin_names.each do |name|
          assert_same_name "/in/#{name}", IOStreams::Utils::PathName.join("/in", name)
          assert_same_name "/in/#{name}", IOStreams::Utils::PathName.join("/in/", name)
          assert_same_name "/in/#{name}", IOStreams::Utils::PathName.dirname("/in/#{name}/x.csv")
          assert_same_name ".c#{name}", IOStreams::Utils::PathName.extname("x.c#{name}")
          assert_same_name "#{name}.csv", IOStreams::Utils::PathName.basename("/in/#{name}.csv")
          assert_same_name name, IOStreams::Utils::PathName.basename("/in/#{name}.csv", ".*")
        end
      end

      it "keeps the bytes of a name that is not valid UTF-8 in a path" do
        assert_equal "/in/caf\xE9".b, IOStreams.path("/in").join(latin).path.b
        assert_equal "/in/caf\xE9".b, IOStreams.path("/in", latin).path.b
        assert_equal "/in/caf\xE9".b, IOStreams.path("/in/#{latin}/x.csv").directory.path.b
        assert_equal "caf\xE9.csv".b, IOStreams.path("/in/#{latin}.csv").basename.b
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
