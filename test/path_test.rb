require_relative "test_helper"

module IOStreams
  class PathTest < Minitest::Test
    describe IOStreams::Path do
      describe ".join" do
        let(:path) { IOStreams::Path.new("some_path") }

        it "returns self when no elements" do
          assert_same path, path.join
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
      end

      describe "#display_name" do
        it "is the full name of the path" do
          %w[/data/a.csv s3://bucket/data/a.csv sftp://example.org:2222/data/a.csv https://example.org:8443/a%20b.csv].each do |url|
            assert_equal url, IOStreams.path(url).display_name
          end
        end

        it "does not include credentials in the url" do
          {
            "sftp://jack:TOP-SECRET@example.org/a.csv?IdentityKey=TOP-SECRET" => "sftp://example.org/a.csv",
            "https://jack:TOP-SECRET@example.org/a.csv?token=TOP-SECRET#x"    => "https://example.org/a.csv"
          }.each_pair do |url, name|
            assert_equal name, IOStreams.path(url).display_name
          end
        end

        it "does not include credentials supplied as arguments" do
          path = IOStreams.path("sftp://example.org/a.csv", username: "jack", password: "TOP-SECRET")

          assert_equal "sftp://example.org/a.csv", path.display_name
        end

        it "does not include the parameters of an HTTP url, which can hold credentials" do
          path = IOStreams.path("https://example.org/a.csv", parameters: {token: "TOP-SECRET"})

          assert_equal "https://example.org/a.csv", path.display_name
        end

        it "is the full name of a joined path" do
          assert_equal "s3://bucket/data/b.csv", IOStreams.path("s3://bucket/data/a.csv").directory.join("b.csv").display_name
        end

        it "shows each byte of a name that is not valid UTF-8 as \\xHH" do
          path = IOStreams.path("/data/caf\xE9.csv".dup.force_encoding(Encoding::UTF_8))

          assert_equal "/data/caf\\xE9.csv", path.display_name
        end
      end

      describe "#inspect" do
        it "includes the class name and path" do
          assert_includes IOStreams::Path.new("a/b/file.csv").inspect, "a/b/file.csv"
        end

        it "includes the full name of the path" do
          {
            "/data/a.csv"                        => "/data/a.csv",
            "s3://bucket/data/a.csv"             => "s3://bucket/data/a.csv",
            "sftp://example.org:2222/data/a.csv" => "sftp://example.org:2222/data/a.csv",
            "https://example.org:8443/a%20b.csv" => "https://example.org:8443/a%20b.csv"
          }.each_pair do |url, name|
            assert_equal "#<#{IOStreams.path(url).class.name}:#{name} pipeline={}>", IOStreams.path(url).inspect
          end
        end

        it "does not display credentials in the url" do
          {
            "sftp://jack:TOP-SECRET@example.org/a.csv?IdentityKey=TOP-SECRET" => "SFTP:sftp://example.org/a.csv ",
            "https://jack:TOP-SECRET@example.org/a.csv?token=TOP-SECRET#x"    => "HTTP:https://example.org/a.csv "
          }.each_pair do |url, name|
            str = IOStreams.path(url).inspect

            refute_includes str, "TOP-SECRET"
            refute_includes str, "jack"
            assert_includes str, name
          end
        end

        it "does not display credentials supplied as arguments" do
          str = IOStreams.path("sftp://example.org/a.csv", username: "jack", password: "TOP-SECRET").inspect

          refute_includes str, "TOP-SECRET"
          assert_includes str, "SFTP:sftp://example.org/a.csv "
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

        it "does not display options whose names suggest a secret" do
          path = IOStreams.path("a/b/file.csv.pgp").option(:pgp, api_token: "TOP-SECRET", recipient: "a@b.org")
          str  = path.inspect

          refute_includes str, "TOP-SECRET"
          assert_includes str, "a@b.org"
        end
      end

      describe ".redact_options" do
        it "replaces the options that the path class declares sensitive" do
          assert_equal({username: "jack", password: "[FILTERED]"},
                       IOStreams::Paths::SFTP.redact_options(username: "jack", password: "secret"))
        end

        it "replaces only the options that are sensitive by name for a path class without secrets" do
          assert_equal({create_path: false, token: "[FILTERED]"}, IOStreams::Path.redact_options(create_path: false, token: "a"))
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
