# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"

# The readers and writers of rows and records with a schema, see IOStreams::Stream#schema, and the copies between a
# stream with a schema and one without, while a stream without a schema reads and writes its rows as before.
class SchemaRowsTest < Minitest::Test
  describe "rows and records" do
    # Returns [Array] the rows or records that the stream yields.
    def read(stream, mode = :array)
      rows = []
      stream.each(mode) { |row| rows << row }
      rows
    end

    def stream(text)
      IOStreams.stream(StringIO.new(text))
    end

    describe "IOStreams::Row::Reader" do
      it "yields the names of the fields of the header row read with a schema as an IOStreams::Row::HeaderRow" do
        rows = read(stream("Zip,Name\n1,Jack\n").schema(fields: [{name: "name"}, {name: "zip"}], fieldsMatch: "equal"))

        assert_equal [%w[name zip], %w[Jack 1]], rows
        assert_instance_of IOStreams::Row::HeaderRow, rows.first
        assert_instance_of Array, rows.last
      end

      it "yields the header row without a schema as an Array, as before" do
        rows = read(stream("Zip,Name\n1,Jack\n"))

        assert_equal [%w[Zip Name], %w[1 Jack]], rows
        assert_instance_of Array, rows.first
      end

      describe "a file without a header row" do
        let(:fixed) { {fields: [{name: "name", width: 4}, {name: "zip", type: "integer", width: 5}]} }

        # Returns [Array] the rows read from the fixed width text.
        def read_fixed(text)
          read(stream(text).format(:fixed).schema(fixed))
        end

        it "yields the names of the fields as an IOStreams::Row::HeaderRow, before the first row" do
          rows = read_fixed("Jack12345\nJill00042\n")

          assert_equal [%w[name zip], ["Jack", 12_345], ["Jill", 42]], rows
          assert_instance_of IOStreams::Row::HeaderRow, rows.first
        end

        it "yields the header row before a blank first line, and nothing for a file without lines" do
          assert_equal [%w[name zip], nil, ["Jack", 12_345]], read_fixed("\nJack12345\n")
          assert_empty read_fixed("")
        end

        it "writes the rows that a loop copies into a file with a header row, which it writes once" do
          output = StringIO.new
          IOStreams.stream(output).format(:csv).writer(:array) do |io|
            stream("Jack12345\n").format(:fixed).schema(fixed).each(:array) { |row| io << row }
          end

          assert_equal "name,zip\nJack,12345\n", output.string
        end

        it "copies the rows into a file whose columns are supplied, which name them instead of the fields" do
          source = stream("Jack12345\n").format(:fixed).schema(fixed)
          output = StringIO.new
          assert_deprecated(/columns: is deprecated/) do
            IOStreams.stream(output).format(:csv).copy_from(source, mode: :array, columns: %w[who where])
          end

          assert_equal "who,where\nJack,12345\n", output.string
        end
      end

      it "makes a row of values from a header row with the methods of an Array that return a new one" do
        header = IOStreams::Row::HeaderRow.new(%w[name zip])

        assert_instance_of Array, header.map(&:upcase)
        assert_instance_of Array, header + ["x"]
        assert_equal %w[name zip], header
      end

      describe "#header?" do
        it "is true when the first row is the header row of the file, or the names of the fields of a file without one" do
          assert stream("name\nJack\n").reader(:array, &:header?)
          assert stream(%({"name":"Jack"}\n)).format(:json).schema(fields: [{name: "name"}]).reader(:array, &:header?)
          assert stream("Jack\n").schema(header: false, fields: [{name: "name"}]).reader(:array, &:header?)
          refute stream(%({"name":"Jack"}\n)).format(:json).reader(:array, &:header?)
          refute(assert_deprecated(/columns: is deprecated/) { stream("Jack\n").reader(:array, columns: %w[name], &:header?) })
        end
      end
    end

    describe "IOStreams::Row::Writer" do
      it "takes the header row that each(:array) yields with a schema as the header row of the rows after it" do
        source = stream("name,id\nJack,1\n").format(:csv).schema(fields: [{name: "name"}, {name: "id"}])
        output = StringIO.new
        IOStreams.stream(output).format(:json).schema(fields: [{name: "id", type: "integer"}, {name: "name"}]).writer(:array) do |io|
          source.each(:array) { |row| io << row }
        end

        assert_equal %({"id":1,"name":"Jack"}\n), output.string
      end

      it "writes an Array of the names of the columns as a row of values, after the header row" do
        output = StringIO.new
        IOStreams.stream(output).format(:json).schema(fields: [{name: "id"}, {name: "name"}]).writer(:array) do |io|
          io << %w[name id]
          io << IOStreams::Row::HeaderRow.new(%w[name id])
          io << %w[Jack 1]
        end

        assert_equal %({"id":"name","name":"id"}\n{"id":"1","name":"Jack"}\n), output.string
      end

      it "writes a header row after the first row as a row of values without a schema, as before" do
        output = StringIO.new
        IOStreams.stream(output).format(:csv).writer(:array) do |io|
          ["name,zip\nJack,1\n", "name,zip\nJill,2\n"].each do |text|
            stream(text).format(:csv).each(:array) { |row| io << row }
          end
        end

        assert_equal "name,zip\nJack,1\nname,zip\nJill,2\n", output.string
      end

      it "takes a header row written to a format without one, without a schema, as the columns of the rows after it" do
        output = StringIO.new
        IOStreams.stream(output).format(:json).writer(:array) do |io|
          io << IOStreams::Row::HeaderRow.new(%w[name zip])
          io << %w[Jack 1]
        end

        assert_equal %({"name":"Jack","zip":"1"}\n), output.string
      end
    end

    describe "blank rows with a schema" do
      let(:schema) { {fields: [{name: "name", constraints: {required: true}}, {name: "age", type: "integer"}]} }

      it "are read as nil, rather than raise for a required field, as a blank line is" do
        assert_equal [nil, {"name" => "Jack", "age" => 21}, nil], read(stream("name,age\n,\nJack,21\n\n").schema(schema), :hash)
      end

      it "still raise for a required field of a row that is not blank" do
        assert_raises(IOStreams::Errors::InvalidValue) { read(stream("name,age\n,21\n").schema(schema), :hash) }
      end

      it "of a fixed width file are a line of only spaces, or whose every field is blank" do
        fixed = {fields: [{name: "name", width: 4}, {name: "age", type: "integer", width: 2}]}

        assert_equal [{"name" => "Jack", "age" => 21}, nil, nil, {"name" => "Jill", "age" => 22}],
                     read(stream("Jack21\n      \n\nJill22\n").format(:fixed).schema(fixed), :hash)
      end
    end

    describe "the text read with a schema" do
      let(:schema) { {fields: [{name: "área"}, {name: "name"}]} }

      it "is UTF-8, so that a column of letters that are not ASCII matches its field" do
        records = read(stream("Área,Name\n12,José\n".b).schema(schema), :hash)

        assert_equal [{"área" => "12", "name" => "José"}], records
        assert_equal Encoding::UTF_8, records.first["name"].encoding
      end

      it "raises for text that is not valid UTF-8, which is an Encoding::UndefinedConversionError" do
        error = assert_raises(IOStreams::Errors::InvalidEncoding) { read(stream("área,name\n12,Jos\xE9\n".b).schema(schema), :hash) }
        assert_kind_of Encoding::UndefinedConversionError, error
        assert_equal "\xE9".b, error.error_char
        assert_match(/\A"\\xE9" is not valid UTF-8/, error.message)
      end

      it "is decoded by an encoding set on the stream instead" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv")
          path.write("area,name\n12,Jos\xE9\n".b)
          records = read(path.encoding("BINARY").schema(fields: [{name: "area"}, {name: "name"}]), :hash)

          assert_equal [{"area" => "12", "name" => "Jos\xE9".b}], records
          assert_equal Encoding::BINARY, records.first["name"].encoding
        end
      end

      it "takes binary text written with a schema as UTF-8, as the values of a file without one that is copied are" do
        out = StringIO.new
        IOStreams.stream(out).format(:json).schema(schema).writer(:hash) { |io| io << {"Área".b => "12", "name" => "José".b} }

        assert_equal %({"área":"12","name":"José"}\n), out.string.dup.force_encoding(Encoding::UTF_8)

        error = assert_raises(IOStreams::Errors::InvalidEncoding) do
          IOStreams.stream(StringIO.new).schema(schema).writer(:array) { |io| io << ["12", "Jos\xE9".b] }
        end
        assert_equal "\xE9".b, error.error_char
      end

      it "is read as before without a schema" do
        rows = read(stream("Área,Name\n12,Jos\xE9\n".b))

        assert_equal [["Área".b, "Name"], ["12", "Jos\xE9".b]], rows
        assert_equal Encoding::BINARY, rows.last.last.encoding
      end
    end

    describe "copying" do
      let(:dir) { Dir.mktmpdir("iostreams") }

      after do
        FileUtils.rm_rf(dir)
      end

      def path(name)
        IOStreams.path(dir, name)
      end

      let(:people) { {fields: [{name: "name"}, {name: "age", type: "integer"}]} }

      it "copies a file without a schema into a file with one, skipping its blank rows, and taking its text as UTF-8" do
        path("in.csv").write("Age,Name\n21,Jack\n\n22,José\n")
        path("out.csv").schema(people).copy_from(path("in.csv"), mode: :array)
        path("out.json").schema(people).copy_from(path("in.csv"), mode: :hash)

        assert_equal "name,age\nJack,21\nJosé,22\n".b, path("out.csv").read
        assert_equal %({"name":"Jack","age":21}\n{"name":"José","age":22}\n).b, path("out.json").read
      end

      it "copies a file with a schema into a file without one, skipping its blank rows" do
        source = path("in.csv").schema(people)
        source.write("name,age\nJack,21\n\nJill,22\n")
        path("out.csv").copy_from(source, mode: :array)
        path("out.json").copy_from(source, mode: :array)
        path("records.csv").copy_from(source, mode: :hash)

        assert_equal "name,age\nJack,21\nJill,22\n", path("out.csv").read
        assert_equal %({"name":"Jack","age":21}\n{"name":"Jill","age":22}\n), path("out.json").read
        assert_equal "name,age\nJack,21\nJill,22\n", path("records.csv").read
      end

      describe "without a schema on either side" do
        it "copies each row read, including the header row, as before" do
          path("in.csv").write("Age,Name\n21,Jack\n")
          path("out.csv").copy_from(path("in.csv"), mode: :array)

          assert_equal "Age,Name\n21,Jack\n", path("out.csv").read
          assert_raises(IOStreams::Errors::InvalidHeader) { path("out.json").copy_from(path("in.csv"), mode: :array) }
        end

        it "raises for a blank row, as before" do
          path("in.csv").write("Age,Name\n\n21,Jack\n")

          error = assert_raises(ArgumentError) { path("out.csv").copy_from(path("in.csv"), mode: :array) }
          assert_equal "Must supply an Array", error.message
          error = assert_raises(ArgumentError) { path("out.csv").copy_from(path("in.csv"), mode: :hash) }
          assert_equal "#<< only accepts a Hash argument", error.message
        end
      end
    end

    describe "a reader or writer created with a tabular" do
      it "raises for the options that create one, which the tabular supplied replaces" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(fields: [{name: "a"}]))

        assert_raises(ArgumentError) { IOStreams::Row::Reader.new([], tabular: tabular, format: :csv) }
        assert_raises(ArgumentError) { IOStreams::Record::Reader.new([], tabular: tabular, original_file_name: "a.csv") }
        assert_raises(ArgumentError) { IOStreams::Row::Writer.new([], tabular: tabular, columns: %w[a]) }
        assert_raises(ArgumentError) { IOStreams::Record::Writer.new([], tabular: tabular, format: :csv) }
      end
    end

    describe "the options of each call without a schema" do
      it "raise for schema:, after the file is opened, as an unknown option did before" do
        error = assert_raises(ArgumentError) { stream("a\n1\n").each(:hash, schema: {fields: []}) { |row| row } }
        assert_match(/\A:schema cannot be supplied to each call/, error.message)
        assert_raises(Errno::ENOENT) { IOStreams.path("/does/not/exist.csv").each(:hash, schema: {fields: []}) { |row| row } }
      end

      it "raise for cleanse_header: when writing, and for options that only apply with a schema, as before" do
        error = assert_raises(ArgumentError) { IOStreams.stream(StringIO.new).writer(:hash, cleanse_header: true) { |io| io << {"a" => 1} } }
        assert_equal "unknown keyword: :cleanse_header", error.message
        error = assert_raises(ArgumentError) { IOStreams::Tabular.new(cleanse_header: true) }
        assert_equal "unknown keyword: :cleanse_header", error.message
        error = assert_raises(ArgumentError) { IOStreams::Tabular.new(decoded: true) }
        assert_match(/\Adecoded: only applies with a schema/, error.message)
      end

      it "still apply the cleansing and restrictions of the header row" do
        assert_equal [{"first_name" => "Jack", "age" => "21"}], read(stream("First Name,Age\nJack,21\n"), :hash)
        records = []
        assert_deprecated(/allowed_columns:, cleanse_header: are deprecated, describe the columns of the file with #schema/) do
          stream("First Name,Age\nJack,21\n").each(:hash, cleanse_header: false, allowed_columns: ["First Name"]) { |r| records << r }
        end

        assert_equal [{"First Name" => "Jack", "Age" => "21"}], records
      end
    end
  end
end
