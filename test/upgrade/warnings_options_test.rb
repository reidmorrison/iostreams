require_relative "../test_helper"
require "json"

# What the deprecation warnings of the options of streams, paths and calls recommend gives the same result on
# IOStreams 2.2 and 3.0, using only the public API of 2.2 that reports no deprecation warning.
class UpgradeWarningsOptionsTest < Minitest::Test
  describe "options" do
    let(:dir) { Dir.mktmpdir("iostreams_upgrade") }
    let(:csv) { "name,zip\nJack,12345\n" }

    after do
      FileUtils.rm_rf(dir)
    end

    # Returns [Array] each record that the block's reader yields.
    def records_of
      records = []
      yield.each(:hash) { |record| records << record }
      records
    end

    describe "leaving out nil column options" do
      it "reads the records of the header row" do
        assert_equal([{"name" => "Jack", "zip" => "12345"}], records_of { IOStreams.stream(StringIO.new(csv)) })
      end

      it "reads the records of the fields of a schema" do
        stream = IOStreams.stream(StringIO.new(csv)).schema(fields: [{name: "name"}, {name: "zip", type: "integer"}])

        assert_equal([{"name" => "Jack", "zip" => 12_345}], records_of { stream })
      end

      it "writes the records by the fields of a schema" do
        io = StringIO.new
        IOStreams.stream(io).schema(fieldsMatch: "subset", fields: [{name: "name"}, {name: "zip"}]).writer(:hash) do |records|
          records << {"name" => "Jack", "address" => "Somewhere", "zip" => 12_345}
        end

        assert_equal csv, io.string
      end
    end

    describe "the options that a stream takes, in place of misspelled ones" do
      it "accepts the options of a stream that the file name does not include, which do not apply" do
        # 2.2 cannot write .xlsx, while 3.0 can, with the options of its writer, such as sheet_name:.
        path = IOStreams.path(dir, "data.csv").option(:pgp, recipient: "receiver@example.org").option(:gz, level: 9).
               option(:xlsx, sheet_name: "Data")
        path.write(csv)

        assert_equal csv, File.read(File.join(dir, "data.csv"))
      end

      it "applies the options of a stream that the file name includes" do
        IOStreams.path(dir, "data.csv.gz").option(:gz, level: 9).write(csv)
        IOStreams.path(dir, "data.zip").option(:zip, entry_file_name: "data.csv").write(csv)

        assert_equal csv, IOStreams.path(dir, "data.csv.gz").read
        assert_equal csv, IOStreams.path(dir, "data.zip").option(:zip, entry_file_name: "data.csv").read
      end

      it "applies the options of a stream set with #stream" do
        io = StringIO.new
        IOStreams.stream(io).stream(:gz, level: 1).write(csv)

        assert_equal csv, IOStreams.stream(StringIO.new(io.string)).stream(:gz).read
      end
    end

    describe "the urls that a path can use" do
      it "reads a percent-encoded '#' in the key of an S3 url" do
        assert_equal "data/a#b.csv", IOStreams.path("s3://bucket/data/a%23b.csv").path
      end

      it "reads a percent-encoded '#' or '?' in the name of an SFTP url" do
        assert_equal "/data/a#b.csv", IOStreams.path("sftp://example.org/data/a%23b.csv").path
        assert_equal "/data/a?b.csv", IOStreams.path("sftp://example.org/data/a%3Fb.csv").path
      end

      it "takes the ssh options of an SFTP path as ssh_options:" do
        path = IOStreams.path("sftp://example.org/data/a.csv", username: "jack", ssh_options: {"IdentityFile" => "~/.ssh/id"})

        assert_equal "/data/a.csv", path.path
        assert_equal({"IdentityFile" => "~/.ssh/id"}, path.ssh_options)
        assert_equal "sftp://example.org/data/a.csv", path.display_name
      end

      it "takes the credentials and the endpoint of an S3 path as arguments" do
        path = IOStreams.path("s3://bucket/data/a.csv", access_key_id: "AKIA", secret_access_key: "secret",
                                                        region: "us-east-1", client: {endpoint: "https://localhost:9000"})

        assert_equal "bucket", path.bucket_name
        assert_equal "data/a.csv", path.path
        assert_equal "s3://bucket/data/a.csv", path.display_name
      end
    end

    describe "the options of the S3 requests of a path" do
      it "takes them as options, and in the query of the url" do
        path = IOStreams.path("s3://bucket/data/a.csv?request_payer=requester", acl: "bucket-owner-full-control")

        assert_equal({acl: "bucket-owner-full-control", request_payer: "requester"}, path.options)
        assert_equal "data/a.csv", path.path
      end
    end

    describe "the settings of a writer that is already open, set where it is opened" do
      it "writes the records to the file of the writer, with its streams and format" do
        IOStreams.path(dir, "data.csv.gz").writer(:hash) do |records|
          IOStreams.stream(records).writer(:hash) { |writer| writer << {"name" => "Jack", "zip" => "12345"} }
        end

        assert_equal csv, IOStreams.path(dir, "data.csv.gz").read
      end

      it "writes the lines to the file of the writer, with its streams" do
        IOStreams.path(dir, "data.txt.gz").writer(:line) do |lines|
          IOStreams.stream(lines).writer(:line) { |writer| writer << "Jack" }
        end

        assert_equal "Jack\n", IOStreams.path(dir, "data.txt.gz").read
      end

      it "writes the records to a line writer in the format of the stream, which applies to them" do
        io = StringIO.new
        IOStreams.stream(io).writer(:line) do |lines|
          IOStreams.stream(lines).format(:json).writer(:hash) { |writer| writer << {"name" => "Jack"} }
          IOStreams.stream(lines).file_name("data.json").writer(:hash) { |writer| writer << {"name" => "Jill"} }
        end

        assert_equal %({"name":"Jack"}\n{"name":"Jill"}\n), io.string
      end
    end

    describe "a schema converted from a layout once, and saved, in place of IOStreams::Schema.from_layout" do
      it "reads a fixed width file by the saved schema" do
        schema = {fields: [{name: "name", type: "string", width: 5, truncate: true}, {name: "zip", type: "integer", width: 5}]}
        File.write(File.join(dir, "schema.json"), JSON.generate(schema))
        File.write(File.join(dir, "data.txt"), "Jack 12345\nJill 23456\n")
        path = IOStreams.path(dir, "data.txt").format(:fixed).schema(File.join(dir, "schema.json"))

        assert_equal([{"name" => "Jack", "zip" => 12_345}, {"name" => "Jill", "zip" => 23_456}], records_of { path })
      end
    end
  end
end
