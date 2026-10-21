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

      describe "#copy_to" do
        # Returns [Array] the rows that copying the lines hands to the writer, through its #<<, see IOStreams::Row::Writer.
        def copied(lines, **)
          written = []
          writer  = Object.new
          writer.define_singleton_method(:<<) { |row| written << row }
          IOStreams::Row::Reader.new(lines, **).copy_to(writer)
          written
        end

        it "hands the header row to the writer as an IOStreams::Row::HeaderRow without a schema, and skips the blank lines" do
          rows = copied(["First Name,Age", "", "Jack,21"], format: :csv)

          assert_equal [["First Name", "Age"], %w[Jack 21]], rows
          assert_instance_of IOStreams::Row::HeaderRow, rows.first
          assert_instance_of Array, rows.last
        end

        it "hands the header row of a file with a schema to the writer as an IOStreams::Row::HeaderRow" do
          schema  = IOStreams::Schema.new(fields: [{name: "name"}, {name: "age", type: "integer"}], fieldsMatch: "equal")
          tabular = IOStreams::Tabular.new(format: :csv, schema: schema)
          rows    = copied(["Age,Name", "21,Jack"], tabular: tabular)

          assert_equal [%w[name age], ["Jack", 21]], rows
          assert_instance_of IOStreams::Row::HeaderRow, rows.first
        end

        it "hands the names of the fields of a file without a header row to the writer once, before its first line" do
          fixed = IOStreams::Schema.new(fields: [{name: "name", width: 4}, {name: "age", type: "integer", width: 2}])
          rows  = copied(%w[Jack21 Jill22], tabular: IOStreams::Tabular.new(format: :fixed, schema: fixed))

          assert_equal [%w[name age], ["Jack", 21], ["Jill", 22]], rows
          assert_instance_of IOStreams::Row::HeaderRow, rows.first
          assert_equal [%w[name age]], copied([], tabular: IOStreams::Tabular.new(format: :fixed, schema: fixed))
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

      it "skips a header row written to a file whose columns are supplied, which name the values of the rows instead" do
        {csv: "who,number\nJack,1\n", json: %({"who":"Jack","number":1}\n)}.each do |format, expected|
          source = stream("name,id\nJack,1\n").format(:csv).schema(fields: [{name: "name"}, {name: "id", type: "integer"}])
          output = StringIO.new
          assert_deprecated(/columns: is deprecated/) do
            IOStreams.stream(output).format(format).writer(:array, columns: %w[who number]) do |io|
              source.each(:array) { |row| io << row }
            end
          end

          assert_equal expected, output.string, format.inspect
        end
      end

      it "raises for a header row written to a fixed width layout, which gives the columns by its keys, rather than write blanks" do
        layout = [{key: :id, size: 3, type: :integer}, {key: :name, size: 5}]
        output = StringIO.new
        target = assert_deprecated(/#format_options is deprecated/) { IOStreams.stream(output).format(:fixed).format_options(layout: layout) }

        error = assert_raises(IOStreams::Errors::InvalidHeader) do
          target.writer(:array) { |io| io << IOStreams::Row::HeaderRow.new(%w[id name]) }
        end
        assert_match(/\AThe header row of the rows written to the :fixed format cannot give its columns/, error.message)
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

      it "leaves binary text written that is not UTF-8 for an encoding set on the stream, which reads it as it is" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.psv").encoding("BINARY").schema(fields: [{name: "id", type: "integer"}, {name: "name"}])
          path.writer(:array) { |io| io << [1, "J\xE9".b] }

          assert_equal "id|name\n1|J\xE9\n".b, File.binread(path.to_s)
          assert_equal [%w[id name], [1, "J\xE9".b]], read(path)

          # Binary text that is UTF-8 is still taken as UTF-8, which the encoding set on the stream encodes.
          latin = IOStreams.path(dir, "people.csv").encoding("ISO-8859-1").schema(fields: [{name: "name"}])
          latin.writer(:array) { |io| io << ["José".b] }

          assert_equal "name\nJos\xE9\n".b, File.binread(latin.to_s)
        end
      end

      it "is read as before without a schema" do
        rows = read(stream("Área,Name\n12,Jos\xE9\n".b))

        assert_equal [["Área".b, "Name"], ["12", "Jos\xE9".b]], rows
        assert_equal Encoding::BINARY, rows.last.last.encoding
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

        it "raises for a line that is not valid UTF-8, naming its line, as IOStreams 3.0 does" do
          error = assert_raises(IOStreams::Errors::InvalidEncoding) do
            read(stream("área,name\n12,Jos\xE9\n".b).schema(schema), :line)
          end
          assert_equal "\xE9".b, error.error_char
          assert_equal 2, error.line_number
          assert_nil error.byte_offset
          assert_equal %("\\xE9" is not valid UTF-8 on line 2. Set the encoding of the file with #encoding), error.message
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

        it "is UTF-8 after stream(:none), which reads the text in its default encoding, as IOStreams 3.0 does" do
          lines = assert_deprecated(/stream\(:none\) is deprecated/) do
            read(stream("área,name\n12,José\n".b).schema(schema).stream(:none), :line)
          end

          assert_equal ["área,name", "12,José"], lines
          assert_equal Encoding::UTF_8, lines.last.encoding
        end

        it "is decoded by the encode stream of a file named .encode instead" do
          Dir.mktmpdir do |dir|
            ::File.binwrite(File.join(dir, "people.csv.encode"), "área,name\n12,José\n".b)
            lines = assert_deprecated(/a file name ending in \.encode is deprecated/) do
              read(IOStreams.path(dir, "people.csv.encode").schema(schema), :line)
            end

            assert_equal ["área,name", "12,José"], lines
          end
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

        it "is read as before without a schema" do
          lines = read(stream("Área,Name\n12,Jos\xE9\n".b), :line)

          assert_equal ["Área,Name".b, "12,Jos\xE9".b], lines
          assert_equal Encoding::BINARY, lines.last.encoding
        end
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

      it "copies a file with a schema into a file whose columns are supplied, which name the values instead of its header row" do
        source = path("in.csv").schema(people)
        source.write("name,age\nJack,21\n")
        assert_deprecated(/columns: is deprecated/) do
          path("out.json").copy_from(source, mode: :array, columns: %w[who years])
          path("out.csv").copy_from(source, mode: :array, columns: %w[who years])
        end

        assert_equal %({"who":"Jack","years":21}\n), path("out.json").read
        assert_equal "who,years\nJack,21\n", path("out.csv").read
      end

      it "raises for a copy into a fixed width layout, which does not match the columns of the header row to its keys" do
        layout = [{key: :id, size: 3, type: :integer}, {key: :name, size: 5}]
        fields = [{name: "id", type: "integer", width: 3}, {name: "name", width: 5}]
        source = path("in.csv").schema(fields: fields)
        source.write("id,name\n1,Jack\n")
        fixed = path("in.fixed").schema(fields: fields)
        fixed.write("001Jack \n")
        target = assert_deprecated(/#format_options is deprecated/) { path("out.fixed").format_options(layout: layout) }

        [source, fixed].each do |input|
          error = assert_raises(IOStreams::Errors::InvalidHeader, input.to_s) { target.copy_from(input, mode: :array) }
          assert_match(/Describe the columns of the file with #schema instead/, error.message)
        end
        assert_raises(IOStreams::Errors::InvalidHeader) { target.writer(:array) { |io| source.each(:array) { |row| io << row } } }

        # A schema gives the width of each field, and matches the columns of the header row to them.
        path("out.fixed").schema(fields: fields).copy_from(source, mode: :array)

        assert_equal "001Jack \n", path("out.fixed").read
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
        %i[hash array].each do |mode|
          error = assert_raises(ArgumentError, mode.inspect) do
            IOStreams.stream(StringIO.new).writer(mode, cleanse_header: true) { |io| io << (mode == :hash ? {"a" => 1} : ["a"]) }
          end
          assert_match(/\Acleanse_header: only applies when reading the header row/, error.message)
        end
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
