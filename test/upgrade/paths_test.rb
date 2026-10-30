# frozen_string_literal: true

require_relative "../test_helper"

# The names and options of paths: #display_name, IOStreams.redact_path_options and IOStreams.redact_stream_options,
# which hide their credentials, and #join and #directory, which return a new path, rather than change one in place,
# which IOStreams 2.2 returns as IOStreams 3.0 does, see `test/upgrade/` in CLAUDE.md.
class UpgradePathsTest < Minitest::Test
  describe IOStreams::Path do
    describe "#display_name" do
      it "is the full name of a local path" do
        assert_equal "/data/people.csv", IOStreams.path("/data/people.csv").display_name
        assert_equal "people.csv", IOStreams.path("people.csv").display_name
      end

      it "leaves out the user name and password of an SFTP url, which #to_s keeps" do
        path = IOStreams.path("sftp://jack:secret@example.org/data/people.csv")

        assert_equal "sftp://example.org/data/people.csv", path.display_name
        assert_equal "sftp://jack:secret@example.org/data/people.csv", path.to_s
        assert_equal "sftp://example.org:2222/data/people.csv", IOStreams.path("sftp://jack@example.org:2222/data/people.csv").display_name
      end

      it "leaves out the user name, password, query and fragment of an HTTP url" do
        assert_equal "https://example.org/people.csv",
                     IOStreams.path("https://jack:secret@example.org/people.csv?X-Amz-Signature=abc#top").display_name
      end

      it "shows each byte of a name that is not valid UTF-8 as \\xHH" do
        assert_equal "/data/caf\\xE9.csv", IOStreams.path("/data/caf\xE9.csv".b).display_name
      end

      it "is the name that #inspect shows" do
        inspected = IOStreams.path("sftp://jack:secret@example.org/data/people.csv").inspect

        assert_includes inspected, "sftp://example.org/data/people.csv"
        refute_includes inspected, "secret"
      end
    end

    describe "IOStreams.redact_path_options" do
      it "replaces the password of an SFTP path, and the IdentityKey of its ssh options, keeping its other options" do
        assert_equal({username: "jack", password: "[FILTERED]"},
                     IOStreams.redact_path_options("sftp://example.org/a.csv", username: "jack", password: "secret"))
        assert_equal({ssh_options: {"IdentityKey" => "[FILTERED]", "Port" => 22}},
                     IOStreams.redact_path_options("sftp://example.org/a.csv", ssh_options: {"IdentityKey" => "key", "Port" => 22}))
      end

      it "replaces the secret access key and the customer encryption key of an S3 path" do
        assert_equal({secret_access_key: "[FILTERED]", sse_customer_key: "[FILTERED]", region: "us-east-1"},
                     IOStreams.redact_path_options("s3://bucket/a.csv", secret_access_key: "x", sse_customer_key: "k", region: "us-east-1"))
      end

      it "replaces the password and the parameters of an HTTP path" do
        assert_equal({username: "jack", password: "[FILTERED]", parameters: "[FILTERED]"},
                     IOStreams.redact_path_options("https://example.org/a.csv", username: "jack", password: "x", parameters: {key: "x"}))
      end

      it "replaces the options whose names suggest a secret, in any case, and those named by Strings" do
        assert_equal({"username" => "jack", "password" => "[FILTERED]"},
                     IOStreams.redact_path_options("sftp://example.org/a.csv", "username" => "jack", "password" => "x"))
        assert_equal({http_token: "[FILTERED]", my_ApiKey: "[FILTERED]", user_agent: "x"},
                     IOStreams.redact_path_options("https://example.org/a.csv", http_token: "t", my_ApiKey: "k", user_agent: "x"))
      end

      it "replaces every option of a url that is not valid, or whose scheme is not registered" do
        assert_equal({username: "[FILTERED]", password: "[FILTERED]"},
                     IOStreams.redact_path_options("http://exa mple.org/%%", username: "jack", password: "x"))
        assert_equal({acl: "[FILTERED]"}, IOStreams.redact_path_options("unknown://bucket/a.csv", acl: "private"))
      end
    end

    describe "IOStreams.redact_stream_options" do
      it "replaces the passphrases of the PGP stream, keeping its other options and the other streams" do
        assert_equal({pgp: {passphrase: "[FILTERED]", recipient: "a@example.org"}, gz: {}},
                     IOStreams.redact_stream_options(pgp: {passphrase: "x", recipient: "a@example.org"}, gz: {}))
        assert_equal({pgp: {signer: "b@example.org", signer_passphrase: "[FILTERED]"}},
                     IOStreams.redact_stream_options(pgp: {signer: "b@example.org", signer_passphrase: "x"}))
      end

      it "replaces every option of a stream that is not registered, or whose options are not a Hash" do
        assert_equal({unknown: {a: "[FILTERED]"}}, IOStreams.redact_stream_options(unknown: {a: 1}))
        assert_equal({pgp: "[FILTERED]"}, IOStreams.redact_stream_options(pgp: "secret"))
      end

      it "replaces the options whose names suggest a secret, within a Hash too, and those named by Strings" do
        assert_equal({"pgp" => {"passphrase" => "[FILTERED]", "recipient" => "a@example.org"}},
                     IOStreams.redact_stream_options("pgp" => {"passphrase" => "x", "recipient" => "a@example.org"}))
        assert_equal({zip: {entry_file_name: "a.csv", "API-Token" => "[FILTERED]", client: {auth: "[FILTERED]"}}},
                     IOStreams.redact_stream_options(zip: {entry_file_name: "a.csv", "API-Token" => "x", client: {auth: "y"}}))
      end

      it "leaves the options supplied as they are" do
        options = {pgp: {passphrase: "x"}}
        IOStreams.redact_stream_options(options)

        assert_equal({pgp: {passphrase: "x"}}, options)
      end
    end

    describe "#join and #directory" do
      let(:dir) { Dir.mktmpdir("iostreams") }

      after do
        FileUtils.rm_rf(dir)
      end

      it "return a new path, and leave the path that they are called on as it is" do
        root = IOStreams.path(dir)
        path = root.join("people.csv")

        refute_same root, path
        assert_equal ::File.join(dir, "people.csv"), path.to_s
        assert_equal ::File.join(dir, "sub", "people.csv"), root.join("sub", "people.csv").to_s
        assert_equal dir, path.directory.to_s
        assert_equal dir, root.to_s
      end

      it "return a path without the streams, options, format, encoding and schema set on the path" do
        root = IOStreams.path(dir).stream(:gz).format(:json).encoding("ISO-8859-1").schema(fields: [{name: "name"}])
        path = root.join("people.csv")

        assert_empty path.pipeline
        assert_equal :csv, path.format
        assert_nil path.encoding
        assert_nil path.schema
        assert_equal({gz: {}}, IOStreams.path(dir, "a.csv.gz").option(:gz, level: 9).join("b.csv.gz").pipeline)

        directory = IOStreams.path(dir, "people.csv").stream(:gz).format(:json).encoding("ISO-8859-1").directory

        assert_empty directory.pipeline
        assert_nil directory.format
        assert_nil directory.encoding
      end

      it "read and write the file of the new path" do
        IOStreams.path(dir).join("people.csv").write("name\nJack\n")

        assert_equal "name\nJack\n", IOStreams.path(dir, "people.csv").read
        assert_equal "name\nJack\n", IOStreams.path(dir, "sub").directory.join("people.csv").read
      end
    end
  end
end
