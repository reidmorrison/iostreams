# frozen_string_literal: true

require_relative "../test_helper"
require_relative "helper"
require "bigdecimal"

# The readers and writers of rows and records with a schema, see IOStreams::Stream#schema, and the copies between a
# stream with a schema and one without, which IOStreams 2.2 reads and writes as IOStreams 3.0 does, see
# `test/upgrade/` in CLAUDE.md.
class UpgradeSchemaRowsTest < Minitest::Test
  describe "rows and records" do
    include UpgradeHelper

    def stream(text)
      IOStreams.stream(StringIO.new(text))
    end

    describe "IOStreams::Row::Reader" do
      it "yields the names of the fields of the header row read with a schema as an IOStreams::Row::HeaderRow" do
        rows = read(stream("Zip,Name\n1,Jack\n").schema(fields: [{name: "name"}, {name: "zip"}], fieldsMatch: "equal"), :array)

        assert_equal [%w[name zip], %w[Jack 1]], rows
        assert_instance_of IOStreams::Row::HeaderRow, rows.first
        assert_instance_of Array, rows.last
      end

      describe "a file without a header row" do
        let(:fixed) { {fields: [{name: "name", width: 4}, {name: "zip", type: "integer", width: 5}]} }

        # Returns [Array] the rows read from the fixed width text.
        def read_fixed(text)
          read(stream(text).format(:fixed).schema(fixed), :array)
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
      end

      it "makes a row of values from a header row with the methods of an Array that return a new one" do
        header = IOStreams::Row::HeaderRow.new(%w[name zip])

        assert_instance_of Array, header.map(&:upcase)
        assert_instance_of Array, header + ["x"]
        assert_equal %w[name zip], header
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
      end

      it "matches the binary keys of the records written with a schema to the fields that their UTF-8 text names" do
        csv  = StringIO.new
        json = StringIO.new
        IOStreams.stream(csv).format(:csv).schema(schema).writer(:hash) { |io| io << {"Área".b => "12", "name".b => "José"} }
        IOStreams.stream(json).format(:json).schema(schema).writer(:hash) { |io| io << {"área".b => "12", "Name" => "José"} }

        assert_equal "área,name\n12,José\n".b, csv.string.b
        assert_equal %({"área":"12","name":"José"}\n).b, json.string.b
      end

      it "matches the binary columns of a header row written with a schema to the fields that their UTF-8 text names" do
        out = StringIO.new
        IOStreams.stream(out).format(:csv).schema(schema).writer(:array) do |io|
          io << IOStreams::Row::HeaderRow.new(["Name".b, "Área".b])
          io << %w[José 12]
        end

        assert_equal "área,name\n12,José\n".b, out.string.b
      end

      it "copies the rows of a file read as binary into a file with a schema, matching its header row to the fields" do
        Dir.mktmpdir do |dir|
          ::File.binwrite(::File.join(dir, "people.csv"), "Name,Área\nJosé,12\n")
          target = IOStreams.path(dir, "copy.csv").schema(schema)
          target.copy_from(IOStreams.path(dir, "people.csv").encoding("BINARY"), mode: :array)

          assert_equal "área,name\n12,José\n".b, ::File.binread(target.to_s)
        end
      end

      it "raises for binary text written with a schema that is not valid UTF-8, which IOStreams 3.0 writes as it is" do
        out   = StringIO.new
        write = -> { IOStreams.stream(out).schema(schema).writer(:array) { |io| io << ["12", "Jos\xE9".b] } }

        if IOStreams::VERSION.to_i >= 3
          # "A schema in v2.2 and v3.0" in docs/upgrading.md of IOStreams 3.0, its bullet on the binary text written.
          write.call

          assert_equal "área,name\n12,Jos\xE9\n".b, out.string.b
        else
          error = assert_raises(IOStreams::Errors::InvalidEncoding, &write)
          assert_equal "\xE9".b, error.error_char
        end
      end

      it "leaves binary text written that is not UTF-8 for an encoding set on the stream, which reads it as it is" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.psv").encoding("BINARY").schema(fields: [{name: "id", type: "integer"}, {name: "name"}])
          path.writer(:array) { |io| io << [1, "J\xE9".b] }

          assert_equal "id|name\n1|J\xE9\n".b, File.binread(path.to_s)
          assert_equal [%w[id name], [1, "J\xE9".b]], read(path, :array)

          # Binary text that is UTF-8 is still taken as UTF-8, which the encoding set on the stream encodes.
          latin = IOStreams.path(dir, "people.csv").encoding("ISO-8859-1").schema(fields: [{name: "name"}])
          latin.writer(:array) { |io| io << ["José".b] }

          assert_equal "name\nJos\xE9\n".b, File.binread(latin.to_s)
        end
      end

      describe "in lines" do
        it "is UTF-8, as the rows and records are" do
          lines = read(stream("Área,Name\n12,José\n".b).schema(schema), :line)

          assert_equal ["Área,Name", "12,José"], lines
          assert_equal [Encoding::UTF_8, Encoding::UTF_8], lines.map(&:encoding)
        end

        it "keeps a newline within a quoted value in its line" do
          lines = read(stream(%(Área,Name\n12,"José\nJack"\n).b).format(:csv).schema(schema), :line)

          assert_equal ["Área,Name", %(12,"José\nJack")], lines
          assert_equal Encoding::UTF_8, lines.last.encoding
        end

        it "raises for a line that is not valid UTF-8, naming its line" do
          error = assert_raises(IOStreams::Errors::InvalidEncoding) do
            read(stream("área,name\n12,Jos\xE9\n".b).schema(schema), :line)
          end
          assert_equal "\xE9".b, error.error_char
          assert_equal 2, error.line_number
        end

        it "names the line of an invalid character within a quoted value" do
          error = assert_raises(IOStreams::Errors::InvalidEncoding) do
            read(stream(%(área,name\n12,"Jack\nJos\xE9"\n).b).format(:csv).schema(schema), :line)
          end
          assert_equal 3, error.line_number
        end

        it "names the line of an invalid character in a row or record, which are read by their lines" do
          error = assert_raises(IOStreams::Errors::InvalidEncoding) do
            read(stream("área,name\n12,José\n13,Jos\xE9\n".b).schema(schema), :hash)
          end
          assert_equal 3, error.line_number
        end

        it "reads the lines as they are stored with #raw, as binary" do
          Dir.mktmpdir do |dir|
            # A gzip header holds the time that it was written, whose bytes can be a line ending, such as "\r", which
            # would split the line read there, so the time is fixed.
            io = StringIO.new(+"")
            gz = Zlib::GzipWriter.new(io)
            gz.mtime = 1
            gz.write("área,name\n12,Jos\xE9\n".b)
            gz.finish
            stored = io.string
            ::File.binwrite(File.join(dir, "people.csv.gz"), stored)
            lines = read(IOStreams.path(dir, "people.csv.gz").schema(schema).raw, :line)

            assert_equal stored.b, lines.join("\n").b
            assert_equal Encoding::BINARY, lines.first.encoding
          end
        end

        it "reads the rows as they are stored with #raw, as binary, as IOStreams 3.0 does" do
          rows = read(stream("area,name\n12,Jos\xE9\n".b).schema(fields: [{name: "area"}, {name: "name"}]).raw, :hash)

          assert_equal [{"area" => "12", "name" => "Jos\xE9".b}], rows
          assert_equal Encoding::BINARY, rows.first["name"].encoding
        end

        it "copies the lines of a file with a schema as UTF-8" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.csv").schema(schema)
            ::File.binwrite(source.to_s, "área,name\n12,José\n".b)
            target = IOStreams.path(dir, "copy.csv")
            target.copy_from(source, mode: :line)

            assert_equal "área,name\n12,José\n", ::File.read(target.to_s, encoding: "UTF-8")

            ::File.binwrite(source.to_s, "área,name\n12,Jos\xE9\n".b)
            error = assert_raises(IOStreams::Errors::InvalidEncoding) { target.copy_from(source, mode: :line) }
            assert_equal 2, error.line_number
          end
        end

        it "is decoded by an encoding set on the stream instead" do
          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "people.csv")
            path.write("area,name\n12,Jos\xE9\n".b)
            lines = read(path.encoding("BINARY").schema(fields: [{name: "area"}, {name: "name"}]), :line)

            assert_equal ["area,name", "12,Jos\xE9".b], lines
            assert_equal Encoding::BINARY, lines.last.encoding
          end
        end
      end
    end

    describe "copying" do
      let(:people) { {fields: [{name: "name"}, {name: "age", type: "integer"}]} }

      it "copies a file without a schema into a file with one, skipping its blank rows, and taking its text as UTF-8" do
        path("in.csv").write("Age,Name\n21,Jack\n\n22,José\n")
        path("out.csv").schema(people).copy_from(path("in.csv"), mode: :array)
        path("out.json").schema(people).copy_from(path("in.csv"), mode: :hash)

        # The bytes written are compared, since #read returns them as binary text in IOStreams 2.2, and as UTF-8 in 3.0,
        # see "Text is read as UTF-8" in docs/upgrading.md of IOStreams 3.0.
        assert_equal "name,age\nJack,21\nJosé,22\n".b, stored("out.csv")
        assert_equal %({"name":"Jack","age":21}\n{"name":"José","age":22}\n).b, stored("out.json")
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
    end
  end
end
