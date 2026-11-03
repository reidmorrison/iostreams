# frozen_string_literal: true

require_relative "../test_helper"
require "bigdecimal"
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

    # `each(:array)`, `each(:hash)` and a copy of the rows and records of a spreadsheet yield the value of each cell as
    # Excel typed it in 3.0, such as the Float `1001.0`, rather than its text, such as `"1001.0"`.
    describe "the cells of a spreadsheet read with a type for each column" do
      let(:path) do
        IOStreams.path(__dir__, "files", "cells.xlsx").schema(
          fields: [
            {name: "id", type: "integer"},
            {name: "amount", type: "number"},
            {name: "zip", type: "string"},
            {name: "ok", type: "boolean"},
            {name: "note", type: "string"}
          ]
        )
      end

      it "are the values of the types of the fields" do
        records = [
          {"id" => 1001, "amount" => BigDecimal("12.5"), "zip" => "01234", "ok" => true, "note" => "x"},
          {"id" => 7, "amount" => BigDecimal("3"), "zip" => "00501", "ok" => false, "note" => nil}
        ]

        assert_equal records, read_all(path, :hash)
        assert_equal [%w[id amount zip ok note], *records.map(&:values)], read_all(path, :array)
      end

      it "reads a number cell into a string field as the number that the cell holds, without a decimal point for a whole number" do
        strings = IOStreams.path(__dir__, "files", "cells.xlsx").schema(fields: %w[id amount zip ok note].map { |name| {name: name, type: "string"} })
        records = [
          {"id" => "1001", "amount" => "12.5", "zip" => "01234", "ok" => "true", "note" => "x"},
          {"id" => "7", "amount" => "3", "zip" => "00501", "ok" => "false", "note" => nil}
        ]

        assert_equal records, read_all(strings, :hash)
      end

      # A whole number below 2**53, which a Float holds exactly, keeps every digit, such as a card number of 16 digits,
      # and any other number has the 15 significant digits that Excel displays, without its number format, such as the
      # 0.125 of 12.5%, in plain digits, rather than an exponent. A cell without a type, as Excel itself writes a number,
      # is a number too. A date and time is the time of its clock, in UTC, and a date is its date.
      it "reads each kind of number cell into the field of its type" do
        numbers = IOStreams.path(__dir__, "files", "numbers.xlsx").schema(
          fields: %w[card small million big general percent].map { |name| {name: name, type: "string"} } +
            [{name: "at", type: "datetime"}, {name: "on", type: "date"}]
        )
        record = {
          "card"    => "4111111111111111",
          "small"   => "0.0000001",
          "million" => "1000000000000000",
          "big"     => "150000000000000000000",
          "general" => "2134",
          "percent" => "0.125",
          "at"      => Time.utc(2026, 10, 25, 9, 30),
          "on"      => Date.new(2026, 10, 25)
        }

        assert_equal [record], read_all(numbers, :hash)
      end

      # Which cells are dates and times is decided by their number formats as Excel defines them: a custom format of only
      # a year, month or day, such as `yyyy-mm-dd` or `dd/mm/yyyy`, is a date, one with hours or seconds too, such as
      # `dd/mm/yyyy hh:mm`, is a date and time, and a `d` or `y` in quoted text, such as `0.00" days"`, is not a date.
      it "reads a cell of a custom date format into a date field as its date" do
        dates = IOStreams.path(__dir__, "files", "dates.xlsx").schema(
          fields: [
            {name: "iso", type: "date"},
            {name: "dmy", type: "date"},
            {name: "at", type: "datetime"},
            {name: "days", type: "number"}
          ]
        )
        record = {
          "iso"  => Date.new(2026, 10, 25),
          "dmy"  => Date.new(2026, 10, 25),
          "at"   => Time.utc(2026, 10, 25, 9, 30),
          "days" => BigDecimal("3.5")
        }

        assert_equal [record], read_all(dates, :hash)
      end

      # A cell of a time of day, of a built-in time format, such as `h:mm:ss`, or a custom one, such as `hh:mm:ss`, is
      # the time of its clock, with the milliseconds that Excel holds when it has any.
      it "reads a cell of a time of day into a string field as the time of its clock" do
        times = IOStreams.path(__dir__, "files", "times.xlsx").schema(
          fields: %w[clock custom half].map { |name| {name: name, type: "string"} }
        )
        record = {"clock" => "09:30:00", "custom" => "09:30:00", "half" => "09:30:00.500"}

        assert_equal [record], read_all(times, :hash)
      end
    end

    # A date field raises `IOStreams::Errors::InvalidValue` in 3.0 for a `Time` or `DateTime` that is not at midnight.
    describe "a date field given a Date, or a time at midnight, and a datetime field given a time" do
      it "writes the date, and the time" do
        io     = StringIO.new
        schema = {fields: [{name: "on", type: "date"}, {name: "at", type: "datetime"}]}
        IOStreams.stream(io).format(:csv).schema(schema).writer(:hash) do |records|
          records << {"on" => Date.new(2026, 10, 25), "at" => Time.utc(2026, 10, 25, 9, 30)}
          records << {"on" => Time.new(2026, 10, 26, 0, 0, 0, "-04:00"), "at" => Time.utc(2026, 10, 26, 17)}
          records << {"on" => Time.utc(2026, 10, 25, 9, 30).to_date, "at" => DateTime.new(2026, 10, 27, 8)}
        end

        assert_equal "on,at\n2026-10-25,2026-10-25T09:30:00Z\n2026-10-26,2026-10-26T17:00:00Z\n" \
                     "2026-10-25,2026-10-27T08:00:00Z\n", io.string
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

    # A copy without a mode converts the format in 3.0.
    describe "a copy into another format with a mode" do
      let(:csv) { "name,age\nJack,21\n" }

      let(:source) do
        File.write(File.join(@dir, "people.csv"), csv)
        IOStreams.path(@dir, "people.csv")
      end

      it "converts the rows with mode: :array, and the records with mode: :hash" do
        assert_equal 2, IOStreams.path(@dir, "people.psv").copy_from(source, mode: :array)
        assert_equal 2, IOStreams.path(@dir, "people.json").copy_from(source, mode: :hash)
        assert_equal 1, IOStreams.path(@dir, "copy.csv").copy_from(IOStreams.path(@dir, "people.json"), mode: :hash)

        assert_equal "name|age\nJack|21\n", File.read(File.join(@dir, "people.psv"))
        assert_equal %({"name":"Jack","age":"21"}\n), File.read(File.join(@dir, "people.json"))
        assert_equal csv, File.read(File.join(@dir, "copy.csv"))
      end

      it "copies the text as it is with mode: :line" do
        assert_equal 2, IOStreams.path(@dir, "people.json").copy_from(source, mode: :line)
        assert_equal csv, File.read(File.join(@dir, "people.json"))
      end

      it "copies the data without a mode within a format, or into a file whose format is not known" do
        assert_equal csv.bytesize, IOStreams.path(@dir, "copy.csv.gz").copy_from(source)
        assert_equal csv.bytesize, IOStreams.path(@dir, "people.txt").copy_from(source)

        assert_equal csv, Zlib.gunzip(File.binread(File.join(@dir, "copy.csv.gz")))
        assert_equal csv, File.read(File.join(@dir, "people.txt"))
      end
    end
  end
end
