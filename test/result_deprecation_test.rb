require_relative "test_helper"
require "pathname"
require "tmpdir"
require "zlib"

# Calls whose result changes in IOStreams v3.0, where another way to write the call gives the same result on both: each
# reports a deprecation warning that names that way, which reports none, and still gives the result that it gave
# before. test/upgrade/results_test.rb shows that the way that each names gives the same result on v2.2 and v3.0.
class ResultDeprecationTest < Minitest::Test
  describe "calls whose result changes in v3.0" do
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

    describe "IOStreams::Pgp.export with email: nil" do
      it "raises IOStreams::Pgp::Failure, and reports that v3.0 raises ArgumentError" do
        assert_deprecated(/IOStreams::Pgp.export with email: nil and without a key_id: is deprecated, since v3.0 raises ArgumentError/) do
          assert_raises(IOStreams::Pgp::Failure) { IOStreams::Pgp.export(email: nil, key_id: nil) }
        end
      end

      it "does not report the email of a key, or neither argument, which raises ArgumentError on both" do
        refute_deprecated do
          assert_match(/BEGIN PGP PUBLIC KEY BLOCK/, IOStreams::Pgp.export(email: "sender@example.org"))
          assert_raises(ArgumentError) { IOStreams::Pgp.export }
          assert_raises(ArgumentError) { IOStreams::Pgp.export(key_id: nil) }
        end
      end
    end

    describe "IOStreams::Pgp.set_trust without an email or key id" do
      it "raises IOStreams::Pgp::Failure, and reports that v3.0 raises ArgumentError" do
        [{}, {email: nil}, {email: nil, key_id: nil, level: 3}].each do |args|
          assert_deprecated(/IOStreams::Pgp.set_trust without an email: or key_id: is deprecated, since v3.0 raises ArgumentError/) do
            assert_raises(IOStreams::Pgp::Failure) { IOStreams::Pgp.set_trust(**args) }
          end
        end
      end

      it "does not report an email" do
        assert_nil(refute_deprecated { IOStreams::Pgp.set_trust(email: "missing@iostreams.net") })
      end
    end

    describe "the rows and records of a file named .text" do
      let(:path) do
        File.write(File.join(@dir, "ids.text"), "id,name\n1,\"a,b\"\n")
        IOStreams.path(@dir, "ids.text")
      end

      let(:text_pattern) { /the rows and records of a file named \.text without #format are deprecated, .* rather than as CSV: set format\(:csv\) on the path/ }

      it "reads them as CSV, and reports that v3.0 reads them in its :text format" do
        assert_equal [%w[id name], ["1", "a,b"]], assert_deprecated(text_pattern) { read_all(path, :array) }
        assert_equal [{"id" => "1", "name" => "a,b"}], assert_deprecated(text_pattern) { read_all(path, :hash) }
        assert_deprecated(text_pattern) { path.reader(:array) { |rows| rows } }
      end

      it "writes them as CSV, and reports it" do
        target = IOStreams.path(@dir, "out.text")
        assert_deprecated(text_pattern) { target.writer(:array) { |rows| rows << %w[a b] } }
        assert_equal "a,b\n", File.read(target.to_s)
        assert_deprecated(text_pattern) { target.writer(:hash) { |records| records << {"a" => 1} } }
        assert_equal "a\n1\n", File.read(target.to_s)
      end

      it "reports a copy of its rows" do
        target = IOStreams.path(@dir, "copy.csv")
        assert_deprecated(text_pattern) { target.copy_from(path, mode: :array) }
        assert_equal "id,name\n1,\"a,b\"\n", File.read(target.to_s)
      end

      it "names the format that it reads them in, of an extension before .text, in any case" do
        File.write(File.join(@dir, "people.json.text"), %({"id":1}\n))
        File.write(File.join(@dir, "IDS.TEXT"), "id\n1\n")

        assert_equal [{"id" => 1}], assert_deprecated(/rather than as JSON: set format\(:json\) on the path/) {
          read_all(IOStreams.path(@dir, "people.json.text"), :hash)
        }
        assert_deprecated(text_pattern) { read_all(IOStreams.path(@dir, "IDS.TEXT"), :array) }
        assert_deprecated(text_pattern) { read_all(IOStreams.stream(StringIO.new("id\n1\n")).file_name("ids.text"), :array) }
      end

      it "does not report its lines, its format, a format that is set, or a file named for another format" do
        refute_deprecated do
          assert_equal ["id,name", "1,\"a,b\""], read_all(path, :line)
          assert_nil path.format
          assert_equal [%w[id name], ["1", "a,b"]], read_all(path.dup.format(:csv), :array)
          File.write(File.join(@dir, "ids.text.csv"), "id\n1\n")

          assert_equal [%w[id], %w[1]], read_all(IOStreams.path(@dir, "ids.text.csv"), :array)
          File.write(File.join(@dir, "text"), "id\n1\n")

          assert_equal [%w[id], %w[1]], read_all(IOStreams.path(@dir, "text"), :array)
        end
      end

      it "does not report a spreadsheet, whose rows v3.0 reads as CSV whatever its name" do
        FileUtils.cp(File.join(__dir__, "files", "spreadsheet.xlsx"), File.join(@dir, "report.text.xlsx"))

        rows = refute_deprecated { read_all(IOStreams.path(@dir, "report.text.xlsx"), :array) }
        assert_equal read_all(IOStreams.path(__dir__, "files", "spreadsheet.xlsx"), :array), rows
      end

      it "does not report a call that supplies the format, which is deprecated itself" do
        assert_deprecated(/format: is deprecated for each call/) { read_all_with(path, format: :csv) }
      end

      def read_all_with(path, **args)
        rows = []
        path.each(:array, **args) { |row| rows << row }
        rows
      end
    end

    describe "each(:array) of JSON without a schema" do
      let(:path) do
        File.write(File.join(@dir, "people.json"), %({"name":"Jack","age":21}\n{"age":22,"name":"Jill"}\n))
        IOStreams.path(@dir, "people.json")
      end

      let(:records_pattern) { /each\(:array\) and reader\(:array\) of a file whose rows are records, such as JSON without a schema, are deprecated, .*read the records with each\(:hash\), or set a schema/ }

      it "yields each record as a Hash, and reports that v3.0 yields Arrays" do
        records = [{"name" => "Jack", "age" => 21}, {"age" => 22, "name" => "Jill"}]

        assert_equal records, assert_deprecated(records_pattern) { read_all(path, :array) }
        assert_deprecated(records_pattern) { path.reader(:array) { |rows| refute_predicate rows, :header? } }
      end

      it "does not report each(:hash), a schema, or a format whose rows are Arrays" do
        refute_deprecated do
          assert_equal [{"name" => "Jack", "age" => 21}, {"age" => 22, "name" => "Jill"}], read_all(path, :hash)
          schema = {fields: [{name: "name"}, {name: "age", type: "integer"}], fieldsMatch: "equal"}

          assert_equal [%w[name age], ["Jack", 21], ["Jill", 22]], read_all(path.dup.schema(schema), :array)
          File.write(File.join(@dir, "people.csv"), "name\nJack\n")

          assert_equal [%w[name], %w[Jack]], read_all(IOStreams.path(@dir, "people.csv"), :array)
        end
      end

      describe "of a registered format without a header row" do
        # Registers the parser for the format while the block runs.
        def with_format(format, parser)
          IOStreams::Tabular.register_format(format, parser)
          yield IOStreams.stream(StringIO.new("a=1;b=2\n")).format(format)
        ensure
          IOStreams::Tabular.deregister_format(format)
        end

        it "reports one whose rows are records, as the class of its parser says" do
          parser = Class.new(IOStreams::Tabular::Parser::Base) do
            def self.keyed? = true
            def parse(line) = line.split(";").to_h { |pair| pair.split("=") }
            def requires_header? = false
          end

          with_format(:iostreams_pairs, parser) do |stream|
            assert_equal [{"a" => "1", "b" => "2"}], assert_deprecated(records_pattern) { read_all(stream, :array) }
          end
        end

        it "does not report one whose rows are Arrays, or whose parser does not say, as one that is not a Base need not" do
          rows = Class.new(IOStreams::Tabular::Parser::Base) do
            def parse(line) = line.split(";")
            def requires_header? = false
          end
          unsaid = Class.new do
            def self.quote_character = nil
            def parse(line) = line.split(";")
            def requires_header? = false
          end

          [rows, unsaid].each do |parser|
            with_format(:iostreams_values, parser) do |stream|
              assert_equal([%w[a=1 b=2]], refute_deprecated { read_all(stream, :array) })
            end
          end
        end
      end
    end

    describe "an SFTP or HTTP url without a path" do
      it "is read as supplied, and reported, since v3.0 adds a / to it" do
        sftp = assert_deprecated(%r{an SFTP url without a path, such as sftp://host, is deprecated, since v3.0 reads it as sftp://host/, the root directory}) do
          IOStreams.path("sftp://example.org")
        end
        assert_equal "sftp://example.org", sftp.to_s
        assert_equal "", sftp.path

        %w[https://example.org https://example.org?a=1 http://user:secret@example.org:8080#top].each do |url|
          http = assert_deprecated(%r{an HTTP url without a path, .* is deprecated, since v3.0 adds a / after the host}) do
            IOStreams.new(url)
          end
          assert_equal url, http.to_s
        end
      end

      it "does not report a url with a path, a name joined to it, or an allowed path, which is the same location on both" do
        refute_deprecated do
          assert_equal "sftp://example.org/", IOStreams.path("sftp://example.org/").to_s
          assert_equal "/a.csv", IOStreams.path("sftp://example.org", "a.csv").path
          assert_equal "https://example.org/?a=1", IOStreams.path("https://example.org/?a=1").to_s
          assert IOStreams.allowed_path?("https://example.org")
          assert_equal "sftp://example.org", IOStreams::Paths::Matcher.new(nil, "sftp://example.org/*.csv").path.to_s
        end
      end
    end

    describe "a name starting with / joined to an S3 bucket" do
      let(:pattern) { %r{joining a name that starts with / to an S3 bucket is deprecated, since v3.0 joins it as a key within the bucket} }

      it "is the key that starts with /, and is reported, since v3.0 joins it as a key within the bucket" do
        assert_equal "/exports/a.csv", assert_deprecated(pattern) { IOStreams.path("s3://bucket").join("/exports/a.csv").path }
        assert_equal "/exports/a.csv", assert_deprecated(pattern) { IOStreams.path("s3://bucket/").join("/exports", "a.csv").path }
      end

      it "does not report a name without a leading /, a key named in the url, or a name joined to a key" do
        refute_deprecated do
          assert_equal "exports/a.csv", IOStreams.path("s3://bucket").join("exports/a.csv").path
          assert_equal "/exports/a.csv", IOStreams.path("s3://bucket//exports/a.csv").path
          assert_equal "dir/a.csv", IOStreams.path("s3://bucket/dir").join("/a.csv").path
        end
      end
    end

    describe "a local file name of ~" do
      let(:pattern) { %r{a local file name of ~, or starting with ~/, is deprecated, since v3.0 reads it within the home directory} }

      it "is within a directory called ~, and is reported, since v3.0 reads it within the home directory" do
        assert_equal "~/data/a.csv", assert_deprecated(pattern) { IOStreams.path("~/data/a.csv").to_s }
        assert_equal "~/a.csv", assert_deprecated(pattern) { IOStreams.path("~", "a.csv").to_s }
        assert_equal "~", assert_deprecated(pattern) { IOStreams.new("~").to_s }
        children = []
        assert_deprecated(pattern) { IOStreams.each_child("~/iostreams-missing-directory/*.csv") { |child| children << child } }
        assert_empty children
        refute assert_deprecated(pattern) { IOStreams.path("~/iostreams-missing.csv").exist? }
      end

      it "does not report an expanded name, a name within ./~, or other names that start with ~" do
        refute_deprecated do
          assert_equal File.join(Dir.home, "a.csv"), IOStreams.path(File.expand_path("~/a.csv")).to_s
          assert_equal "./~/a.csv", IOStreams.path("./~/a.csv").to_s
          assert_equal "~user/a.csv", IOStreams.path("~user/a.csv").to_s
          assert_equal "~$Book1.xlsx", IOStreams.path("~$Book1.xlsx").to_s
          assert_equal File.join(@dir, "~/a.csv"), IOStreams.path(@dir).join("~/a.csv").to_s
        end
      end

      it "is not reported by a matcher, which other gems create themselves, such as Rocket Job" do
        assert_equal("~/data", refute_deprecated { IOStreams::Paths::Matcher.new(nil, "~/data/*.csv").path.to_s })
      end
    end

    describe "a file:// url" do
      let(:pattern) { %r{a file:// url is deprecated, since v3.0 reads it as the local file that it names} }

      it "is a file name relative to the current directory, and is reported, since v3.0 reads the file that it names" do
        assert_equal "file://~/data/a.csv", assert_deprecated(pattern) { IOStreams.path("file://~/data/a.csv").to_s }
        assert_equal "file://~", assert_deprecated(pattern) { IOStreams.new("file://~").to_s }
        assert_predicate assert_deprecated(pattern) { IOStreams.path("file:///data/a.csv") }, :relative?
        assert_equal "FILE://localhost/a.csv", assert_deprecated(pattern) { IOStreams.path("FILE://localhost/a.csv").to_s }
        assert assert_deprecated(pattern) { IOStreams.allowed_path?("file:///data") }
        children = []
        assert_deprecated(pattern) { IOStreams.each_child("file:///iostreams-missing-directory/*.csv") { |child| children << child } }
        assert_empty children
      end

      it "does not report the name of the file, a name that does not start with file://, or a matcher" do
        refute_deprecated do
          assert_equal "/data/a.csv", IOStreams.path("/data/a.csv").to_s
          assert_equal "file:~/a.csv", IOStreams.path("file:~/a.csv").to_s
          assert_equal "data/file://a.csv", IOStreams.path("data/file://a.csv").to_s
          assert_equal "file:///data", IOStreams::Paths::Matcher.new(nil, "file:///data/*.csv").path.to_s
        end
      end
    end

    describe "a Pathname" do
      let(:pathname) do
        file_name = File.join(@dir, "data.csv.gz")
        File.binwrite(file_name, Zlib.gzip("a,b\n"))
        Pathname.new(file_name)
      end

      let(:new_pattern) { /a Pathname supplied to IOStreams.new, #copy_from, #copy_to or #move_to is deprecated, since v3.0 takes it as the name of a file/ }

      it "is read as an IO, and reported, since v3.0 reads the file that it names" do
        stream = assert_deprecated(new_pattern) { IOStreams.new(pathname) }
        assert_instance_of IOStreams::Stream, stream
        assert_equal Zlib.gzip("a,b\n").bytesize, stream.read.bytesize

        # A copy to it writes the data as it is stored, where v3.0 compresses it for its .gz file name. A copy from it is
        # not tested, since on JRuby it never ends: Pathname#read(length) always returns the start of the file.
        source = IOStreams.path(@dir, "source.csv")
        source.write("a,b\n")
        target = Pathname.new(File.join(@dir, "copy.csv.gz"))
        assert_deprecated(new_pattern) { source.copy_to(target) }

        assert_equal "a,b\n", File.binread(target.to_s)

        assert_deprecated(/a Pathname supplied to IOStreams.stream is deprecated, since v3.0 raises ArgumentError/) do
          assert_instance_of IOStreams::Stream, IOStreams.stream(pathname)
        end
      end

      it "does not report its name, or IOStreams.path, which read the file that it names on both" do
        refute_deprecated do
          assert_equal "a,b\n", IOStreams.new(pathname.to_s).read
          assert_equal "a,b\n", IOStreams.path(pathname).read
          assert_equal File.binread(pathname.to_s), IOStreams.path(pathname).raw.read
        end
      end
    end

    describe "IOStreams.temp_file" do
      let(:pattern) { /reading or writing the path of IOStreams.temp_file is deprecated when its extension names streams, such as .gz, since v3.0 applies them/ }

      it "reads and writes the data as it is stored, and reports it when its extension names streams" do
        IOStreams.temp_file("iostreams", ".csv.gz") do |path|
          assert_deprecated(pattern) { path.write("a,b\n") }
          assert_equal "a,b\n", File.binread(path.to_s)
          assert_equal "a,b\n", assert_deprecated(pattern) { path.read }
          assert_equal [%w[a b]], assert_deprecated(pattern) { read_all(path.dup, :array) }
        end
      end

      it "does not report #raw, streams set on it, an extension without streams, a copy without conversion, or its name" do
        refute_deprecated do
          IOStreams.temp_file("iostreams", ".csv.gz") do |path|
            path.raw.write("a,b\n")

            assert_equal "a,b\n", path.raw.read
            IOStreams.path(@dir, "a.csv").copy_from(path, convert: false)

            assert_equal "a,b\n", File.read(File.join(@dir, "a.csv"))
            IOStreams.path(path.to_s).write("c,d\n")

            assert_equal "c,d\n", IOStreams.path(path.to_s).read
          end
          IOStreams.temp_file("iostreams", ".csv.gz") do |path|
            path.stream(:gz).write("a,b\n")

            assert_equal "a,b\n", Zlib.gunzip(File.binread(path.to_s))
          end
          IOStreams.temp_file("iostreams", ".csv") do |path|
            path.write("a,b\n")

            assert_equal "a,b\n", path.read
          end
        end
      end
    end

    describe "an option of another extension of a format" do
      it "is not applied to the extension in the file name, and is reported, since v3.0 applies it" do
        path = IOStreams.path(@dir, "a.gpg").option(:pgp, recipient: "receiver@example.org")
        assert_deprecated(/option\(:pgp, \.\.\.\) is deprecated for a file name with the extension \.gpg, which v2.2 does not apply it to, .*: set them with option\(:gpg, \.\.\.\)/) do
          error = assert_raises(ArgumentError) { path.write("x") }
          assert_includes error.message, "Requires either :recipient or :import_and_trust_key"
        end

        path = IOStreams.path(@dir, "a.gzip").option(:gz, level: 9)
        assert_deprecated(/option\(:gz, \.\.\.\) is deprecated for a file name with the extension \.gzip/) { path.write("a,b\n") }
        assert_equal({gzip: {}}, path.pipeline)
        assert_equal "a,b\n", Zlib.gunzip(File.binread(path.to_s))
      end

      it "does not report the option of the extension itself, or one that it also sets" do
        refute_deprecated do
          path = IOStreams.path(@dir, "a.gpg").option(:gpg, recipient: "receiver@example.org")
          path.write("x")

          assert_equal "x", IOStreams.path(@dir, "a.gpg").option(:gpg, passphrase: "receiver_passphrase").read

          path = IOStreams.path(@dir, "b.gzip").option(:gz, level: 9).option(:gzip, level: 1)
          path.write("a,b\n")

          assert_equal({gzip: {level: 1}}, path.pipeline)
        end
      end
    end
  end
end
