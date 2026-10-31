# frozen_string_literal: true

require_relative "../test_helper"
require "pathname"
require "tmpdir"
require "zlib"

# The calls whose result IOStreams 3.0 changes, which IOStreams 2.2 reports as deprecated, naming another way to write
# the call: each test here shows that way giving the same result on 2.2 and 3.0, see `test/upgrade/` in CLAUDE.md. The
# bullets of the "Breaking" section of the 3.0.0 CHANGELOG on `main` that each one is for are named in its describe block.
class UpgradeResultsTest < Minitest::Test
  describe "calls whose result changes in 3.0" do
    before do
      @dir = Dir.mktmpdir("iostreams")
    end

    after do
      FileUtils.rm_rf(@dir)
    end

    # Returns [Array] what the path yields in the mode.
    def read_all(path, mode)
      rows = []
      path.each(mode) { |row| rows << row }
      rows
    end

    # `IOStreams::Pgp.export(email: nil)` without a `key_id:` raises ArgumentError in 3.0.
    describe "IOStreams::Pgp.export with the email or key id of the key" do
      it "returns the key, and raises ArgumentError without either" do
        assert_match(/BEGIN PGP PUBLIC KEY BLOCK/, IOStreams::Pgp.export(email: "sender@example.org"))
        assert_raises(ArgumentError) { IOStreams::Pgp.export }
        assert_raises(IOStreams::Pgp::Failure) { IOStreams::Pgp.export(email: "missing@iostreams.net") }
      end
    end

    # `IOStreams::Pgp.set_trust` without an `email:` or `key_id:` raises ArgumentError in 3.0.
    describe "IOStreams::Pgp.set_trust with the email of the key" do
      it "trusts the key, or returns nil when there is none" do
        assert_kind_of String, IOStreams::Pgp.set_trust(email: "sender@example.org", level: 5)
        assert_nil IOStreams::Pgp.set_trust(email: "missing@iostreams.net")
      end
    end

    # A file named `.text` is read in the `:text` format in 3.0.
    describe "a file named .text with format(:csv)" do
      let(:path) do
        File.write(File.join(@dir, "ids.text"), "id,name\n1,\"a,b\"\n2,\"c\nd\"\n")
        IOStreams.path(@dir, "ids.text").format(:csv)
      end

      it "reads its lines, rows and records as CSV" do
        assert_equal ["id,name", "1,\"a,b\"", "2,\"c\nd\""], read_all(path, :line)
        assert_equal [%w[id name], ["1", "a,b"], ["2", "c\nd"]], read_all(path, :array)
        assert_equal [{"id" => "1", "name" => "a,b"}, {"id" => "2", "name" => "c\nd"}], read_all(path, :hash)
      end

      it "writes its rows and records as CSV" do
        target = IOStreams.path(@dir, "out.text").format(:csv)
        target.writer(:array) do |rows|
          rows << %w[id name]
          rows << ["1", "a,b"]
        end

        assert_equal "id,name\n1,\"a,b\"\n", File.read(target.to_s)

        target.writer(:hash) { |records| records << {"id" => "2", "name" => "c"} }

        assert_equal "id,name\n2,c\n", File.read(target.to_s)
      end
    end

    # `each(:array)` yields the rows of JSON as Arrays in 3.0.
    describe "the records of JSON" do
      let(:path) do
        File.write(File.join(@dir, "people.json"), %({"name":"Jack","age":21}\n{"age":22,"name":"Jill"}\n))
        IOStreams.path(@dir, "people.json")
      end

      it "are Hashes read with each(:hash)" do
        assert_equal [{"name" => "Jack", "age" => 21}, {"age" => 22, "name" => "Jill"}], read_all(path, :hash)
      end

      it "are rows read with a schema, after a header row of the names of its fields" do
        rows = read_all(path.schema(fields: [{name: "name"}, {name: "age", type: "integer"}], fieldsMatch: "equal"), :array)

        assert_equal [%w[name age], ["Jack", 21], ["Jill", 22]], rows
        assert_instance_of IOStreams::Row::HeaderRow, rows.first
      end
    end

    # An SFTP or HTTP(S) url without a path ends with `/` in 3.0.
    describe "an SFTP or HTTP url with a path of /" do
      it "keeps the /" do
        sftp = IOStreams.path("sftp://example.org/")

        assert_equal "sftp://example.org/", sftp.to_s
        assert_equal "/", sftp.path
        assert_equal IOStreams.path("sftp://example.org/"), sftp

        http = IOStreams.path("https://example.org/?a=1")

        assert_equal "https://example.org/?a=1", http.to_s
        assert_equal "/", http.path
      end

      it "joins a name within the root directory" do
        assert_equal "/a.csv", IOStreams.path("sftp://example.org/").join("a.csv").path
        assert_equal "/a.csv", IOStreams.path("sftp://example.org", "a.csv").path
        assert_equal "sftp://example.org/a.csv", IOStreams.path("sftp://example.org", "a.csv").to_s
      end
    end

    # A name joined to an S3 bucket is a key within it in 3.0.
    describe "a name joined to an S3 bucket without a leading /" do
      it "is a key within the bucket" do
        path = IOStreams.path("s3://bucket").join("exports/a.csv")

        assert_equal "exports/a.csv", path.path
        assert_equal "s3://bucket/exports/a.csv", path.to_s
        assert_equal "exports/a.csv", IOStreams.path("s3://bucket/").join("exports", "a.csv").path
      end

      it "names a key that starts with / in the url" do
        assert_equal "/exports/a.csv", IOStreams.path("s3://bucket//exports/a.csv").path
      end
    end

    # A local `~` is the home directory in 3.0.
    describe "a local name expanded with File.expand_path, or within ./~" do
      it "is the file within the home directory, or within the directory called ~" do
        assert_equal File.join(Dir.home, "data", "a.csv"), IOStreams.path(File.expand_path("~/data/a.csv")).to_s
        assert_equal "./~/data/a.csv", IOStreams.path("./~/data/a.csv").to_s
        assert_predicate IOStreams.path("./~/data/a.csv"), :relative?
      end

      it "reads and writes a file within a directory called ~" do
        path = IOStreams.path(@dir, "~", "a.csv")
        path.write("a,b\n")

        assert_equal "a,b\n", File.read(File.join(@dir, "~", "a.csv"))
        assert_equal "a,b\n", path.read
      end
    end

    # A Pathname names a file in 3.0.
    describe "the name of a Pathname" do
      let(:pathname) do
        file_name = File.join(@dir, "data.csv.gz")
        File.binwrite(file_name, Zlib.gzip("a,b\n"))
        Pathname.new(file_name)
      end

      it "is the path of the file, which applies the streams of its file name" do
        assert_equal "a,b\n", IOStreams.new(pathname.to_s).read
        assert_equal "a,b\n", IOStreams.path(pathname).read
        assert_equal File.binread(pathname.to_s), IOStreams.path(pathname).raw.read
      end

      it "is copied from and to, applying the streams of its file name" do
        target = IOStreams.path(@dir, "copy.csv")
        target.copy_from(pathname.to_s)

        assert_equal "a,b\n", File.read(target.to_s)

        copy = Pathname.new(File.join(@dir, "copy.csv.gz"))
        target.copy_to(copy.to_s)

        assert_equal "a,b\n", Zlib.gunzip(File.binread(copy.to_s))
      end
    end

    # `IOStreams.temp_file` applies the streams that its extension implies in 3.0.
    describe "the path of IOStreams.temp_file" do
      it "reads and writes the data as it is stored with #raw" do
        IOStreams.temp_file("iostreams", ".csv.gz") do |path|
          path.raw.write("a,b\n")

          assert_equal "a,b\n", File.binread(path.to_s)
          assert_equal "a,b\n", path.raw.read
        end
      end

      it "applies the streams set on it, and of the extension of a path of its name" do
        IOStreams.temp_file("iostreams", ".csv.gz") do |path|
          path.stream(:gz).write("a,b\n")

          assert_equal "a,b\n", Zlib.gunzip(File.binread(path.to_s))
          assert_equal "a,b\n", IOStreams.path(path.to_s).read
        end
      end

      it "reads and writes a file whose extension implies no streams" do
        IOStreams.temp_file("iostreams", ".csv") do |path|
          path.write("a,b\n")

          assert_equal "a,b\n", File.read(path.to_s)
          assert_equal [%w[a b]], read_all(path, :array)
        end
      end
    end

    # An option for a format applies to each of its extensions in 3.0.
    describe "the options of the extension in the file name" do
      it "apply to it" do
        path = IOStreams.path(@dir, "a.gpg").option(:gpg, recipient: "receiver@example.org")

        assert_equal({gpg: {recipient: "receiver@example.org"}}, path.pipeline)

        path.write("hello")

        assert_equal "hello", IOStreams.path(@dir, "a.gpg").option(:gpg, passphrase: "receiver_passphrase").read
      end

      it "take precedence over those of another extension of its format" do
        path = IOStreams.path(@dir, "a.gzip").option(:gz, level: 9).option(:gzip, level: 1)

        assert_equal({gzip: {level: 1}}, path.pipeline)

        path.write("a,b\n")

        assert_equal "a,b\n", Zlib.gunzip(File.binread(path.to_s))
      end
    end
  end
end
