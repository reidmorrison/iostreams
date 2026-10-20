# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "json"

# The rows and records of a stream with a schema, see IOStreams::Stream#schema, as IOStreams 3.0 reads and writes them.
class StreamSchemaTest < Minitest::Test
  describe IOStreams::Stream do
    let(:stream) { IOStreams::Stream.new(StringIO.new) }

    describe "#schema" do
      let(:people) do
        {
          fields: [
            {name: "id", type: "integer"},
            {name: "pay", type: "number", decimals: 2},
            {name: "joined", type: "date"},
            {name: "active", type: "boolean"}
          ]
        }
      end

      let(:csv) { "id,pay,joined,active\n0042,12.5,2026-10-13,true\n" }

      let(:record) { {"id" => 42, "pay" => BigDecimal("12.5"), "joined" => Date.new(2026, 10, 13), "active" => true} }

      # Returns [Array] the rows or records read from the text, with the supplied file name and schema.
      def read(text, mode = :hash, file_name: "people.csv", schema: people)
        rows = []
        IOStreams::Stream.new(StringIO.new(text)).file_name(file_name).schema(schema).each(mode) { |row| rows << row }
        rows
      end

      # Returns [String] the text written for the records, with the supplied file name and schema.
      def write(records, mode = :hash, file_name: "people.csv", schema: people)
        out = StringIO.new
        IOStreams::Stream.new(out).file_name(file_name).schema(schema).writer(mode) do |io|
          records.each { |record| io << record }
        end
        out.string
      end

      # Returns [IOStreams::Row::HeaderRow] the columns as a header row, as each(:array) yields it, which a writer of rows
      # takes as the header row of the rows after it.
      def header_row(*columns)
        IOStreams::Row::HeaderRow.new(columns)
      end

      it "returns the schema that was set" do
        assert_nil stream.schema
        assert_same stream, stream.schema(people)
        assert_equal people, stream.schema

        stream.schema = "s3://bucket/people.json"

        assert_equal "s3://bucket/people.json", stream.schema

        stream.schema = nil

        assert_nil stream.schema
      end

      it "keeps the schema as it was set, when the Hash supplied is changed afterwards" do
        supplied = {fields: [{name: "id", type: "integer"}]}
        stream.schema(supplied)
        supplied[:fields] << {name: "name"}
        supplied[:fields].first[:type] = "string"

        assert_equal({fields: [{name: "id", type: "integer"}]}, stream.schema)
        assert_equal [{"id" => 42}], read("id\n0042\n", schema: stream.schema)
        refute_predicate supplied, :frozen?
      end

      it "cannot be changed through the schema that it returns" do
        stream.schema(people)

        assert_raises(FrozenError) { stream.schema[:fields] << {name: "name"} }
        assert_raises(FrozenError) { stream.schema[:fields].first[:type] = "string" }
        assert_equal people, stream.schema
      end

      # A copy of a path shares its streams and options with the path, as every copy of a path does in IOStreams 2.
      it "keeps the path of a schema file as it was set, when the path supplied is changed afterwards" do
        Dir.mktmpdir do |dir|
          supplied = IOStreams.path(dir, "people.json")
          supplied.write(JSON.generate(people))
          stream.schema(supplied)
          assert_deprecated(/#path= is deprecated/) { supplied.path = ::File.join(dir, "other.json") }

          assert_equal ::File.join(dir, "people.json"), stream.schema.to_s
          assert_equal [record], read(csv, schema: stream.schema)
        end
      end

      it "checks a schema in a Hash when it is set" do
        assert_raises(ArgumentError) { stream.schema(fields: [{name: "id", type: "money"}]) }
        assert_nil stream.schema
      end

      it "raises when the schema is not a Hash, or a path or url" do
        error = assert_raises(ArgumentError) { stream.schema([{name: "id"}]) }
        assert_match(/\AA schema must be a Hash, or the path or url of a JSON file/, error.message)
      end

      it "raises for a frozen path" do
        path = IOStreams.path("/data/people.csv").freeze

        assert_raises(FrozenError) { path.schema(people) }
      end

      it "converts the values of the records read" do
        assert_equal [record], read(csv)
      end

      it "converts the values of the rows read, but not the header row" do
        assert_equal [%w[id pay joined active], [42, BigDecimal("12.5"), Date.new(2026, 10, 13), true]], read(csv, :array)
      end

      it "applies to every format" do
        json = %({"id":"0042","pay":12.5,"joined":"2026-10-13","active":true}\n)

        assert_equal [record], read(json, file_name: "people.json")
        assert_equal [record], read("id|pay|joined|active\n0042|12.5|2026-10-13|true\n", file_name: "people.psv")
      end

      it "skips the columns that the schema does not list, when fieldsMatch skips them" do
        partial = people.merge(fieldsMatch: "partial")

        assert_equal [{"id" => 1}], read("id,name\n1,Jack\n", schema: partial)
        assert_equal [["id"], [1]], read("id,name\n1,Jack\n", :array, schema: partial)
        assert_equal [{"id" => 1}], read(%({"id":1,"name":"Jack"}\n), file_name: "people.json", schema: partial)
      end

      it "raises for the columns that the schema does not list, unless fieldsMatch skips them" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) { read("id,pay,joined,active,name\n1,2,2026-10-13,true,Jack\n") }
        assert_match(/\AThe header row does not match the schema: the column "name" is not a field of the schema/, error.message)
      end

      it "matches the columns of a header row and the keys of JSON to the fields, whose names are the keys of the records" do
        schema = {fields: [{name: "first_name", type: "string"}, {name: "Age", type: "integer"}]}

        assert_equal [{"first_name" => "Jack", "Age" => 21}], read("First Name,AGE\nJack,21\n", schema: schema)
        assert_equal [{"first_name" => "Jack", "Age" => 21}], read(%({"First Name":"Jack","age":"21"}\n), file_name: "people.json", schema: schema)
      end

      it "raises for a value that is not of the type of its field" do
        error = assert_raises(IOStreams::Errors::InvalidValue) { read("id\n12-\n", schema: people.merge(fieldsMatch: "partial")) }
        assert_equal 'Field "id": "12-" is not a valid integer', error.message
      end

      it "writes each value in the text form of its type" do
        written = write([{id: "0042", pay: 12.5, joined: Date.new(2026, 10, 13), active: "1"}])

        assert_equal "id,pay,joined,active\n42,12.50,2026-10-13,true\n", written
        assert_equal [record], read(written)
      end

      it "writes rows in the text form of the type of each field, after a header row of the names of the fields" do
        written = write([["0042", 12.5, Date.new(2026, 10, 13), "1"]], :array)

        assert_equal "id,pay,joined,active\n42,12.50,2026-10-13,true\n", written
      end

      it "writes a header row of the names of the fields when no row is written, as writer(:hash) does" do
        assert_equal "id,pay,joined,active\n", write([], :array)
        assert_equal "id,pay,joined,active\n", write([], :hash)
        assert_equal "", write([], :array, schema: people.merge(header: false))
        assert_equal "", write([], :array, file_name: "people.json")

        out = StringIO.new
        IOStreams::Stream.new(out).file_name("people.csv").schema(people).writer(:array) { |_io| break }

        assert_equal "id,pay,joined,active\n", out.string

        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv").schema(people)
          assert_raises(RuntimeError) { path.writer(:array) { |_io| raise "boom" } }

          refute_predicate path, :exist?
        end
      end

      it "copies a file without rows into a file with a header row, which still has its header row" do
        Dir.mktmpdir do |dir|
          IOStreams.path(dir, "empty.csv").write("")
          target = IOStreams.path(dir, "out.csv").schema(people)
          target.copy_from(IOStreams.path(dir, "empty.csv"), mode: :array)

          assert_equal "id,pay,joined,active\n", target.read
        end
      end

      it "matches the columns of a header row written, as each(:array) yields it, so that the rows after it can be in any order" do
        written = write([header_row("Active", "ID", "Joined", "Pay"), ["1", "0042", Date.new(2026, 10, 13), 12.5]], :array)

        assert_equal "id,pay,joined,active\n42,12.50,2026-10-13,true\n", written
      end

      it "writes JSON numbers and booleans as themselves" do
        written = write([record], file_name: "people.json")

        assert_equal %({"id":42,"pay":12.50,"joined":"2026-10-13","active":true}\n), written
        assert_equal [record], read(written, file_name: "people.json")
      end

      it "writes every digit of a JSON number, with and without JSON::Coder" do
        schema = {fields: [{name: "pay", type: "number"}]}
        long   = BigDecimal("12345678901234567.890123")

        assert_equal %({"pay":12345678901234567.890123}\n), write([{"pay" => long}], file_name: "people.json", schema: schema)
        IOStreams::Tabular::Parser::JsonFields.stub(:coder, nil) do
          assert_equal %({"pay":12345678901234567.890123}\n), write([{"pay" => long}], file_name: "people.json", schema: schema)
        end
      end

      it "reads every digit of a JSON number of a number field, and the other numbers as Floats, as without a schema" do
        schema = {fields: [{name: "amount", type: "number"}, {name: "rate"}, {name: "count", type: "integer"}, {name: "tags"}]}
        rows   = read(%({"amount":12345678901234567.89,"rate":1.5,"count":3.0,"tags":[2.5,{"x":0.1}]}\n), file_name: "people.json", schema: schema)

        assert_equal [{"amount" => BigDecimal("12345678901234567.89"), "rate" => 1.5, "count" => 3, "tags" => [2.5, {"x" => 0.1}]}], rows
        assert_kind_of Float, rows.first["rate"]
        assert_kind_of Float, rows.first["tags"].first
        assert_kind_of Float, rows.first["tags"].last["x"]
      end

      it "writes and reads back every digit of a JSON number" do
        schema  = {fields: [{name: "amount", type: "number", decimals: 2}]}
        written = write([{"amount" => BigDecimal("12345678901234567.89")}], file_name: "people.json", schema: schema)

        assert_equal %({"amount":12345678901234567.89}\n), written
        assert_equal [{"amount" => BigDecimal("12345678901234567.89")}], read(written, file_name: "people.json", schema: schema)
      end

      it "reads a JSON line of null, or of a record without keys, as nil, as rows and as records" do
        schema = {fields: [{name: "id", type: "integer"}]}
        json   = %({"id":1}\nnull\n{"id":2}\n{}\n)

        assert_equal [%w[id], [1], nil, [2], nil], read(json, :array, file_name: "people.json", schema: schema)
        assert_equal [{"id" => 1}, nil, {"id" => 2}, nil], read(json, file_name: "people.json", schema: schema)
      end

      it "reads each JSON row as the value of every field, in order, after a header row of the names of the fields, nil for a key that its record does not have" do
        superset = people.merge(fieldsMatch: "superset")
        json     = %({"active":"1","id":"0042"}\n{"pay":12.5,"joined":"2026-10-13","id":7,"active":false}\n)

        assert_equal [%w[id pay joined active], [42, nil, nil, true], [7, BigDecimal("12.5"), Date.new(2026, 10, 13), false]],
                     read(json, :array, file_name: "people.json", schema: superset)
        assert IOStreams::Stream.new(StringIO.new(json)).file_name("people.json").schema(superset).reader(:array, &:header?)
      end

      it "matches the keys of each JSON record read as a row to the fields, as for records" do
        json = %({"id":1,"pay":2,"joined":"2026-10-13","active":true,"name":"Jack"}\n)

        assert_equal [%w[id pay joined active], [1, BigDecimal("2"), Date.new(2026, 10, 13), true]],
                     read(json, :array, file_name: "people.json", schema: people.merge(fieldsMatch: "subset"))
        error = assert_raises(IOStreams::Errors::InvalidHeader) { read(json, :array, file_name: "people.json") }
        assert_match(/\AThe keys of a record do not match the schema: the key "name" is not a field/, error.message)

        required = {fieldsMatch: "superset", fields: [{name: "id", type: "integer"}, {name: "name", constraints: {required: true}}]}
        error    = assert_raises(IOStreams::Errors::InvalidHeader) { read(%({"id":1}\n), :array, file_name: "people.json", schema: required) }
        assert_match(/missing the required field "name"/, error.message)
      end

      it "copies the rows of JSON into a file with a header row of the names of the fields, and into JSON again" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "people.json").schema(people)
          source.write(%({"active":true,"joined":"2026-10-13","pay":12.5,"id":"0042"}\n))
          IOStreams.path(dir, "people.csv").copy_from(source, mode: :array)
          IOStreams.path(dir, "copy.json").schema(people).copy_from(source, mode: :array)
          IOStreams.path(dir, "plain.json").copy_from(source, mode: :array)

          # A target without a schema writes each value as it did before, such as a BigDecimal as its `to_s`.
          assert_equal "id,pay,joined,active\n42,0.125e2,2026-10-13,true\n", IOStreams.path(dir, "people.csv").read
          assert_equal %({"id":42,"pay":12.50,"joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "copy.json").read
          assert_equal %({"id":42,"pay":"0.125e2","joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "plain.json").read
        end
      end

      it "raises for a value after the last column, such as one after a comma that is not quoted" do
        schema = {fields: [{name: "name"}, {name: "city"}]}

        error = assert_raises(IOStreams::Errors::InvalidHeader) { read("name,city\nSmith, John,Boston\n", schema: schema) }
        assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)
        assert_raises(IOStreams::Errors::InvalidHeader) { read("name,city\nSmith, John,Boston\n", :array, schema: schema) }
        assert_raises(IOStreams::Errors::InvalidHeader) { read("Smith, John,Boston\n", schema: schema.merge(header: false)) }
        assert_raises(IOStreams::Errors::InvalidHeader) { read("name|city\nSmith|John|Boston\n", file_name: "people.psv", schema: schema) }
        assert_equal [{"name" => "Jack", "city" => "Paris"}], read("name,city\nJack,Paris,\n", schema: schema)
      end

      it "yields a header row of its own, so that changing it does not change the schema" do
        schema = JSON.parse(%({"fields":[{"name":"id","type":"integer"},{"name":"name"}]}))
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv").schema(schema)
          path.write("id,name\n1,Jack\n")
          path.each(:array) { |row| row.each { |value| value.upcase! if value.is_a?(String) } }
          rows = []
          path.each(:hash) { |row| rows << row }

          assert_equal [{"id" => 1, "name" => "Jack"}], rows
          assert_equal "id", schema["fields"].first["name"]
        end
      end

      it "copies the rows of a file into a file with a schema, matching the columns of the header row of the source" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "in.csv")
          source.write("Age,Name\n21,Jack\n22,Jill\n")
          target = IOStreams.path(dir, "out.csv").schema(fields: [{name: "name"}, {name: "age", type: "integer"}])
          target.copy_from(source, mode: :array)

          assert_equal "name,age\nJack,21\nJill,22\n", target.read

          copy = IOStreams.path(dir, "copy.csv").schema(target.schema)
          target.copy_to(copy, mode: :array)

          assert_equal "name,age\nJack,21\nJill,22\n", copy.read
        end
      end

      it "copies the rows of a file with a header row into a format without one, taking its columns from it" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "in.csv")
          source.write("Age,Name\n21,Jack\n")
          target = IOStreams.path(dir, "out.json").schema(fields: [{name: "name"}, {name: "age", type: "integer"}])
          target.copy_from(source, mode: :array)

          assert_equal %({"name":"Jack","age":21}\n), target.read

          # Without a schema on either side, the header row is copied as the first row, as before, which JSON cannot write
          # without its columns.
          plain = IOStreams.path(dir, "plain.json")
          assert_raises(IOStreams::Errors::InvalidHeader) { plain.copy_from(source, mode: :array) }
        end
      end

      it "copies the header row as a row when the columns are supplied, which it does not replace, as before" do
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "in.csv")
          source.write("Age,Name\n21,Jack\n")

          json = IOStreams.path(dir, "out.json")
          assert_deprecated(/columns: is deprecated/) { json.copy_from(source, mode: :array, columns: %w[age name]) }

          assert_equal %({"age":"Age","name":"Name"}\n{"age":"21","name":"Jack"}\n), json.read

          csv = IOStreams.path(dir, "out.csv")
          assert_deprecated(/columns: is deprecated/) { csv.copy_from(source, mode: :array, columns: %w[age name]) }

          assert_equal "age,name\nAge,Name\n21,Jack\n", csv.read
        end
      end

      it "writes the rows read with a schema whose fields can be missing in the columns of their fields" do
        schema = {fieldsMatch: "superset", fields: [{name: "name"}, {name: "age", type: "integer"}, {name: "score", type: "integer"}]}
        Dir.mktmpdir do |dir|
          source = IOStreams.path(dir, "in.csv").schema(schema)
          source.write("name,score\nJack,90\n")
          target = IOStreams.path(dir, "out.csv").schema(schema)
          target.copy_from(source, mode: :array)

          assert_equal "name,age,score\nJack,,90\n", target.read
          assert_equal [%w[name age score], ["Jack", nil, 90]], read(target.read, :array, schema: schema)
        end
      end

      it "raises when writing a value that is not of the type of its field" do
        assert_raises(IOStreams::Errors::InvalidValue) { write([{"id" => "abc"}]) }
      end

      it "reads the schema from a file the first time that it is needed" do
        Dir.mktmpdir do |dir|
          schema_path = ::File.join(dir, "people.json")
          path        = IOStreams.path(dir, "people.csv").schema(schema_path)
          IOStreams.path(dir, "people.csv").write(csv)

          assert_raises(Errno::ENOENT) { path.each(:hash) { |row| row } }

          IOStreams.path(schema_path).write(JSON.generate(people))
          rows = []
          path.each(:hash) { |row| rows << row }

          assert_equal [record], rows
          assert_equal schema_path, path.schema
        end
      end

      it "is read once for a path and its copies" do
        Dir.mktmpdir do |dir|
          schema_path = IOStreams.path(dir, "people.json")
          schema_path.write(JSON.generate(people))
          path = IOStreams.path(dir, "people.csv").schema(schema_path)
          path.write(csv)
          path.each(:hash) { |row| row }
          copy = IOStreams.path(path)
          schema_path.delete
          rows = []
          copy.each(:hash) { |row| rows << row }

          assert_equal [record], rows
        end
      end

      it "is kept by a copy, and cleared by #join" do
        path = IOStreams.path("/data/people.csv").schema(people)

        assert_equal people, IOStreams.path(path).schema
        assert_nil path.join("other.csv").schema
        assert_nil path.directory.schema
      end

      describe "matching columns to fields" do
        let(:contacts) do
          {
            fields: [
              {name: "first_name"},
              {name: "email", aliases: ["E-mail Address"]},
              {name: "date_of_birth", type: "date", aliases: ["DOB", "Birth Date"]}
            ]
          }
        end

        it "matches a column whose name differs only in case, spaces and punctuation" do
          assert_equal [{"first_name" => "Jack", "email" => "j@x.com", "date_of_birth" => Date.new(2001, 2, 3)}],
                       read("FIRST NAME,E-mail,Date of Birth\nJack,j@x.com,2001-02-03\n", schema: contacts)
        end

        it "matches a column to an alias of its field" do
          assert_equal [{"first_name" => "Jack", "email" => "j@x.com", "date_of_birth" => Date.new(2001, 2, 3)}],
                       read("First Name,E-mail Address,DOB\nJack,j@x.com,2001-02-03\n", schema: contacts)
        end

        it "matches the keys of JSON the same way" do
          json = %({"First Name":"Jack","EMAIL":"j@x.com","birth_date":"2001-02-03"}\n)

          assert_equal [{"first_name" => "Jack", "email" => "j@x.com", "date_of_birth" => Date.new(2001, 2, 3)}],
                       read(json, file_name: "people.json", schema: contacts)
        end

        it "raises for two columns that are the same field, rather than lose one of them" do
          error = assert_raises(IOStreams::Errors::InvalidHeader) { read("first_name,email,DOB,Email\nJack,a,2001-02-03,b\n", schema: contacts) }
          assert_equal 'The columns "email" and "Email" are both the field "email", so either could be meant', error.message
        end

        it "returns the names of the fields as they are given, as the keys of the records" do
          schema = {fields: [{name: :id, type: "integer"}, {name: "Name"}]}

          assert_equal [{id: 1, "Name" => "Jack"}], read("ID,name\n1,Jack\n", schema: schema)
          assert_equal [[:id, "Name"], [1, "Jack"]], read("ID,name\n1,Jack\n", :array, schema: schema)
        end

        it "writes the names of the fields as the header row, from records whose keys match them" do
          readable = {fields: [{name: "First Name"}, {name: "Date of Birth", type: "date"}]}
          written  = write([{first_name: "Jack", date_of_birth: Date.new(2001, 2, 3)}], schema: readable)

          assert_equal "First Name,Date of Birth\nJack,2001-02-03\n", written
          assert_equal [{"first_name" => "Jack", "date_of_birth" => Date.new(2001, 2, 3)}],
                       read(written, schema: {fields: [{name: "first_name"}, {name: "date_of_birth", type: "date"}]})
        end
      end

      describe "matching columns to their cleansed names" do
        it "matches the field named as the column once cleansed, which drops the characters that Unicode makes digits" do
          assert_equal [{"area_m" => "12", "score" => "3"}], read("Area (m²),Score ①\n12,3\n", schema: {fields: [{name: "area_m"}, {name: "score"}]})
          assert_equal "Area (m²)\n12\n", write([{"area_m" => 12}], schema: {fields: [{name: "Area (m²)"}]})
        end
      end

      describe "fieldsMatch" do
        let(:fields) { [{name: "id", type: "integer"}, {name: "name"}] }

        # Returns [Array|String] the records read from the CSV text, or the message of the error that it raises.
        def records(text, fields_match = nil, file_name: "people.csv")
          schema = {fields: fields}
          schema[:fieldsMatch] = fields_match if fields_match
          read(text, file_name: file_name, schema: schema)
        rescue IOStreams::Errors::InvalidHeader => e
          e.message
        end

        it "defaults to exact: the columns are the fields, in order" do
          assert_equal [{"id" => 1, "name" => "Jack"}], records("id,name\n1,Jack\n")
          assert_match(/not in the order of the fields/, records("name,id\nJack,1\n"))
          assert_match(/missing the field "name"/, records("id\n1\n"))
          assert_match(/the column "age" is not a field/, records("id,name,age\n1,Jack,21\n"))
        end

        it "equal: the columns are the fields, in any order" do
          assert_equal [{"id" => 1, "name" => "Jack"}], records("name,id\nJack,1\n", "equal")
          assert_match(/missing the field "name"/, records("id\n1\n", "equal"))
        end

        it "subset: skips the columns that the schema does not list" do
          assert_equal [{"id" => 1, "name" => "Jack"}], records("age,name,id\n21,Jack,1\n", "subset")
          assert_match(/missing the field "name"/, records("id,age\n1,21\n", "subset"))
        end

        it "superset: accepts missing fields, but not other columns" do
          assert_equal [{"id" => 1}], records("id\n1\n", "superset")
          assert_match(/the column "age" is not a field/, records("id,age\n1,21\n", "superset"))
        end

        it "partial: skips the other columns, and needs at least one field" do
          assert_equal [{"name" => "Jack"}], records("age,name\n21,Jack\n", "partial")
          assert_match(/no column is a field of the schema/, records("age\n21\n", "partial"))
        end

        it "ignores the columns without a name at the end of the header row, which a spreadsheet exports" do
          assert_equal [{"id" => 1, "name" => "Jack"}], records("id,name,,\n1,Jack,,\n")
          assert_equal [{"id" => 1, "name" => "Jack"}], records("id,name, \n1,Jack,\n", "equal")
        end

        it "raises for a value in a column without a name at the end of the header row, unless it skips it" do
          assert_match(/1 value after the last column/, records("id,name,\n1,Jack,x\n"))
          assert_equal [{"id" => 1, "name" => "Jack"}], records("id,name,\n1,Jack,x\n", "subset")
        end

        it "raises for a column without a name between other columns, unless it skips it" do
          assert_match(/a column without a name is not a field of the schema/, records("id,,name\n1,,Jack\n"))
          assert_equal [{"id" => 1, "name" => "Jack"}], records("id,,name\n1,x,Jack\n", "subset")
        end

        it "applies to the keys of each JSON record, in any order" do
          assert_equal [{"id" => 1, "name" => "Jack"}], records(%({"name":"Jack","id":1}\n), file_name: "people.json")
          assert_match(/\AThe keys of a record do not match the schema: missing the field "name"/,
                       records(%({"id":1,"name":"Jack"}\n{"id":2}\n), file_name: "people.json"))
          assert_equal [{"id" => 1}, {"id" => 2, "name" => "Jill"}],
                       records(%({"id":1}\n{"id":2,"name":"Jill","age":3}\n), "partial", file_name: "people.json")
        end

        it "skips the keys, and the values after the last field, that it skips when reading, when writing" do
          schema = {fields: fields, fieldsMatch: "subset"}

          assert_equal "id,name\n1,Jack\n", write([{"age" => 21, "name" => "Jack", "id" => 1}], schema: schema)
          assert_equal "id,name\n1,Jack\n", write([header_row("id", "name", "age"), [1, "Jack", 21]], :array, schema: schema)
          assert_equal "id,name\n1,Jack\n", write([header_row("id", "name"), [1, "Jack", 21]], :array, schema: schema)
          assert_equal "id,name\n1,Jack\n", write([[1, "Jack", 21]], :array, schema: schema)
          assert_equal %({"id":1,"name":null}\n), write([{id: 1, age: 2}], file_name: "people.json", schema: schema)
        end

        it "raises for the keys, and the values after the last field, that it does not accept when writing" do
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([{"id" => 1, "age" => 21}], schema: {fields: fields}) }
          assert_match(/\AThe keys of a record do not match the schema: the key "age" is not a field/, error.message)

          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name"), [1, "Jack", 21]], :array, schema: {fields: fields}) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)

          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([[1, "Jack", 21]], :array, schema: {fields: fields}) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last field/, error.message)

          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name", "age"), [1, "Jack", 21]], :array, schema: {fields: fields}) }
          assert_match(/\AThe header row does not match the schema: the column "age" is not a field/, error.message)
        end

        it "ignores the columns without a name at the end of the header row written, as when reading" do
          assert_equal "id,name\n1,Jack\n", write([header_row("id", "name", nil, ""), [1, "Jack", nil, ""]], :array, schema: {fields: fields})

          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name", nil), [1, "Jack", 21]], :array, schema: {fields: fields}) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)
        end

        it "takes a column at the end of the header row that is not blank text as a column, as it takes a value there" do
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name", false), [1, "Jack"]], :array, schema: {fields: fields}) }
          assert_match(/\AThe header row does not match the schema: the column false is not a field/, error.message)

          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name"), [1, "Jack", false]], :array, schema: {fields: fields}) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)
        end

        it "skips a column whose bytes are not valid in its encoding when it skips the others, rather than raise" do
          invalid = (+"Caf\xE9").force_encoding(Encoding::UTF_8)
          schema  = {fields: fields, fieldsMatch: "subset"}

          assert_equal "id,name\n1,Jack\n", write([header_row("id", "name", invalid), [1, "Jack", 2]], :array, schema: schema)
          assert_equal "id,name\n1,Jack\n", write([{"id" => 1, "name" => "Jack", invalid => 2}], schema: schema)
          assert_equal "id,name\n1,Jack\n", write([header_row("id", "name"), [1, "Jack", invalid]], :array, schema: schema)
        end

        it "raises for a header row written without a column that is a field, such as a row of values, rather than write empty rows" do
          %w[subset partial].each do |fields_match|
            error = assert_raises(IOStreams::Errors::InvalidHeader, fields_match) do
              write([header_row("Jack", 21), ["Jill", 22]], :array, schema: {fields: fields, fieldsMatch: fields_match})
            end
            assert_equal 'The header row does not match the schema: the columns "Jack" and 21 are not fields of the schema, ' \
                         "so the rows after it would have no value for any field. A header row names the column of each " \
                         "value of the rows after it, so give it the names of the fields, or of their columns, or write " \
                         "rows of the values of the fields, in order, without one", error.message
          end
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row, [1, "Jack"]], :array, schema: {fields: fields, fieldsMatch: "subset"}) }
          assert_match(/\AThe header row does not match the schema: it has no columns, so the rows after it would have no value/, error.message)
          assert_equal "id,name\n,Jack\n", write([header_row("name", "x"), %w[Jack 21]], :array, schema: {fields: fields, fieldsMatch: "subset"})
        end

        it "ignores a blank value after the last field or column when writing, as reading does, but not false" do
          schema = {fields: fields}

          assert_equal "id,name\n1,Jack\n2,Jill\n", write([[1, "Jack", nil], [2, "Jill", " "]], :array, schema: schema)
          assert_equal "1,Jack\n", write([[1, "Jack", ""]], :array, schema: schema.merge(header: false))
          assert_equal %({"id":1,"name":"Jack"}\n), write([[1, "Jack", nil]], :array, file_name: "people.json", schema: schema)
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([[1, "Jack", false]], :array, schema: schema) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last field/, error.message)
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write([header_row("id", "name"), [1, "Jack", false]], :array, schema: schema) }
          assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)
        end

        it "copies the rows of a file with a delimiter at the end of each line into a schema that accepts no other values" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "in.csv")
            source.write("id,name,\n1,Jack,\n")
            target = IOStreams.path(dir, "out.csv").schema(fields: fields, fieldsMatch: "subset")
            target.copy_from(IOStreams.path(dir, "in.csv"), mode: :array)

            assert_equal "id,name\n1,Jack\n", target.read

            source.write("id,name\n1,Jack,\n")
            target = IOStreams.path(dir, "out.csv").schema(fields: fields)
            target.copy_from(source, mode: :array)

            assert_equal "id,name\n1,Jack\n", target.read
          end
        end

        it "matches the keys of each record written, when they change from one record to the next" do
          records = [{"id" => 1, "name" => "Jack"}, {"name" => "Jill", "ID" => 2}, {"id" => 3}, {"id" => 4, "age" => 9}]
          schema  = {fields: fields, fieldsMatch: "subset"}

          assert_equal "id,name\n1,Jack\n2,Jill\n3,\n4,\n", write(records, schema: schema)
          error = assert_raises(IOStreams::Errors::InvalidHeader) { write(records.first(3) + [{"id" => 4, "age" => 9}], schema: {fields: fields}) }
          assert_match(/the key "age" is not a field/, error.message)
          assert_raises(IOStreams::Errors::InvalidHeader) { write([{"id" => 1, "name" => "a"}, {"id" => 2, "age" => 9}], schema: {fields: fields}) }
        end

        it "writes every field, even when a record does not supply it" do
          assert_equal "id,name\n1,\n", write([{"id" => 1}], schema: {fields: fields})
          assert_equal %({"id":1,"name":null}\n), write([{"id" => 1}], file_name: "people.json", schema: {fields: fields})
        end
      end

      describe "required fields" do
        let(:schema) { {fieldsMatch: "partial", fields: [{name: "id", type: "integer"}, {name: "email", constraints: {required: true}}]} }

        it "raises when the header row does not have the field, whatever fieldsMatch is" do
          error = assert_raises(IOStreams::Errors::InvalidHeader) { read("id,name\n1,Jack\n", schema: schema) }
          assert_equal 'The header row does not match the schema: missing the required field "email"', error.message
        end

        it "raises for a value that is empty" do
          assert_equal [{"id" => 1, "email" => "j@x.com"}], read("id,email\n1,j@x.com\n", schema: schema)
          error = assert_raises(IOStreams::Errors::InvalidValue) { read("id,email\n1,\n", schema: schema) }
          assert_equal 'Field "email" is required, but has no value', error.message
        end

        it "raises for a JSON record without the key, or with null" do
          assert_raises(IOStreams::Errors::InvalidHeader) { read(%({"id":1}\n), file_name: "people.json", schema: schema) }
          assert_raises(IOStreams::Errors::InvalidValue) { read(%({"id":1,"email":null}\n), file_name: "people.json", schema: schema) }
        end

        it "raises when writing a record without a value" do
          assert_raises(IOStreams::Errors::InvalidValue) { write([{"id" => 1}], schema: schema) }
          assert_raises(IOStreams::Errors::InvalidValue) { write([{"id" => 1, "email" => ""}], file_name: "people.json", schema: schema) }
        end

        it "raises when writing a blank record or row, which has no value for it" do
          assert_raises(IOStreams::Errors::InvalidValue) { write([{}], schema: schema) }
          assert_raises(IOStreams::Errors::InvalidValue) { write([{}], file_name: "people.json", schema: schema) }
          assert_raises(IOStreams::Errors::InvalidValue) { write([%w[id email], []], :array, schema: schema) }
        end

        it "writes the records after one that it rejects with the keys of their own" do
          records = [{"id" => 1}, {"email" => "j@x.com"}, {"email" => "k@x.com"}]
          out     = StringIO.new
          IOStreams::Stream.new(out).file_name("people.csv").schema(schema).writer(:hash) do |io|
            records.each do |record|
              io << record
            rescue IOStreams::Errors::InvalidValue
              nil
            end
          end

          assert_equal "id,email\n,j@x.com\n,k@x.com\n", out.string
        end

        describe "that allow blank values" do
          let(:schema) do
            {fieldsMatch: "partial", fields: [{name: "id", type: "integer"}, {name: "email", constraints: {required: true}, allowBlank: true}]}
          end

          it "reads a blank value, but still raises when the header row does not have the field" do
            assert_equal [{"id" => 1, "email" => nil}], read("id,email\n1,\n", schema: schema)
            error = assert_raises(IOStreams::Errors::InvalidHeader) { read("id,name\n1,Jack\n", schema: schema) }
            assert_equal 'The header row does not match the schema: missing the required field "email"', error.message
          end

          it "reads a JSON record with null, but raises for one without the key" do
            assert_equal [{"id" => 1, "email" => nil}], read(%({"id":1,"email":null}\n), file_name: "people.json", schema: schema)
            assert_raises(IOStreams::Errors::InvalidHeader) { read(%({"id":1}\n), file_name: "people.json", schema: schema) }
          end

          it "writes a record without a value, and a blank record" do
            assert_equal "id,email\n1,\n", write([{"id" => 1}], schema: schema)
            assert_equal %({"id":1,"email":null}\n{"id":2,"email":""}\n),
                         write([{"id" => 1, "email" => nil}, {"id" => 2, "email" => ""}], file_name: "people.json", schema: schema)
            assert_equal "id,email\n\n", write([{}], schema: schema)
          end
        end
      end

      describe "the options of each call that describe the columns" do
        it "raise with a schema, which describes the columns instead" do
          stream = IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").schema(people)
          {columns: %w[id], allowed_columns: %w[id], required_columns: %w[id]}.each_pair do |name, value|
            error = assert_raises(ArgumentError) { stream.each(:hash, name => value) { |row| row } }
            assert_match(/\A#{name}: cannot be supplied with a schema/, error.message)
          end
          assert_raises(ArgumentError) { stream.each(:array, columns: %w[id]) { |row| row } }
        end

        it "accept skip_unknown without allowed_columns, which it only applies to" do
          stream = IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").schema(people)
          rows   = []
          assert_deprecated(/skip_unknown: is deprecated/) { stream.each(:hash, skip_unknown: false) { |row| rows << row } }

          assert_equal [record], rows
        end

        it "raise an unknown option as an unknown keyword, as without a schema" do
          stream = IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").schema(people)

          error = assert_raises(ArgumentError) { stream.each(:hash, delimitr: "\n") { |row| row } }
          assert_equal "unknown keyword: :delimitr", error.message
        end

        it "raise for cleanse_header with a schema, whose fields name the keys of the records" do
          stream = IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").schema(people)

          [true, false].each do |cleanse|
            error = assert_raises(ArgumentError) { stream.each(:hash, cleanse_header: cleanse) { |row| row } }
            assert_match(/\Acleanse_header: cannot be supplied with a schema/, error.message)
            assert_raises(ArgumentError) { stream.each(:array, cleanse_header: cleanse) { |row| row } }
          end
        end

        it "raise for cleanse_header with a schema before the file is opened" do
          path = IOStreams.path("/does/not/exist/people.csv").schema(people)

          error = assert_raises(ArgumentError) { path.each(:hash, cleanse_header: false) { |row| row } }
          assert_match(/\Acleanse_header: cannot be supplied with a schema/, error.message)
        end

        it "raise when writing with a schema, or copying to a target with one" do
          out = IOStreams::Stream.new(StringIO.new).file_name("people.csv").schema(people)
          assert_raises(ArgumentError) { out.writer(:hash, columns: %w[id]) { |io| io } }

          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "source.csv")
            source.write(csv)
            assert_raises(ArgumentError) { IOStreams.path(dir, "target.csv").schema(people).copy_from(source, mode: :hash, columns: %w[id]) }
          end
        end

        it "keep cleanse_header: nil meaning not to cleanse the header row without a schema, as before" do
          [[{}, "first_name"], [{cleanse_header: true}, "first_name"], [{cleanse_header: false}, "First Name"],
           [{cleanse_header: nil}, "First Name"]].each do |options, key|
            rows = []
            read = -> { IOStreams::Stream.new(StringIO.new("First Name\nJack\n")).file_name("a.csv").each(:hash, **options) { |row| rows << row } }
            options.empty? ? read.call : assert_deprecated(/cleanse_header: is deprecated, describe the columns/, &read)

            assert_equal [{key => "Jack"}], rows, options.inspect
          end
        end

        it "still apply without a schema, and to the layout of the format options" do
          rows = []
          assert_deprecated(/allowed_columns: is deprecated/) do
            IOStreams::Stream.new(StringIO.new(csv)).file_name("people.csv").each(:hash, allowed_columns: %w[id]) { |row| rows << row }
          end

          assert_equal [{"id" => "0042"}], rows

          fixed = IOStreams::Stream.new(StringIO.new("07abc\n")).format(:fixed)
          assert_deprecated(/#format_options is deprecated/) do
            fixed.format_options(layout: [{size: 2, key: :id, type: :integer}, {size: 3, key: :code}])
          end
          rows = []
          assert_deprecated(/columns: is deprecated/) { fixed.each(:hash, columns: ["id"]) { |row| rows << row } }

          assert_equal [{"id" => 7}], rows
        end
      end

      describe "a file without a header row" do
        let(:headerless) { people.merge(header: false) }

        it "reads every line as a record of the fields" do
          assert_equal [record], read("0042,12.5,2026-10-13,true\n", schema: headerless)
          assert_equal [%w[id pay joined active], [42, BigDecimal("12.5"), Date.new(2026, 10, 13), true]],
                       read("0042,12.5,2026-10-13,true\n", :array, schema: headerless)
        end

        it "writes no header row, and the fields in order" do
          written = write([{active: true, joined: Date.new(2026, 10, 13), pay: 12.5, id: 42}], schema: headerless)

          assert_equal "42,12.50,2026-10-13,true\n", written
        end

        it "is ignored by a format without a header row, such as JSON, whose fieldsMatch can then be any of them" do
          partial = headerless.merge(fieldsMatch: "partial")

          assert_equal [{"id" => 42}], read(%({"id":"0042","notes":"x"}\n), file_name: "people.json", schema: partial)
          assert_equal %({"id":42,"pay":null,"joined":null,"active":null}\n), write([{"id" => 42, "notes" => "x"}], file_name: "people.json", schema: partial)
          error = assert_raises(ArgumentError) { read("0042\n", schema: partial) }
          assert_match(/\AA schema with header: false has the fields in order, so fieldsMatch must be "exact"/, error.message)
        end

        it "copies its rows into a file with a header row, whose columns are the fields, whatever fieldsMatch the target has" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.csv").schema(headerless)
            source.write("0042,12.5,2026-10-13,true\n")
            %w[exact equal subset superset partial].each do |fields_match|
              target = IOStreams.path(dir, "out.csv").schema(people.merge(fieldsMatch: fields_match))
              target.copy_from(source, mode: :array)

              assert_equal "id,pay,joined,active\n42,12.50,2026-10-13,true\n", target.read, fields_match
            end

            IOStreams.path(dir, "plain.csv").copy_from(source, mode: :array)
            IOStreams.path(dir, "plain.json").copy_from(source, mode: :array)
            IOStreams.path(dir, "copy.csv").schema(headerless).copy_from(source, mode: :array)

            # A target without a schema writes each value as it did before, such as a BigDecimal as its `to_s`.
            assert_equal "id,pay,joined,active\n42,0.125e2,2026-10-13,true\n", IOStreams.path(dir, "plain.csv").read
            assert_equal %({"id":42,"pay":"0.125e2","joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "plain.json").read
            assert_equal "42,12.50,2026-10-13,true\n", IOStreams.path(dir, "copy.csv").read
          end
        end

        it "copies its rows into a file whose columns are supplied, which give the columns of the rows instead" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.csv").schema(headerless)
            source.write("0042,12.5,2026-10-13,true\n")
            assert_deprecated(/columns: is deprecated/) do
              IOStreams.path(dir, "out.csv").copy_from(source, mode: :array, columns: %w[a b c d])
              IOStreams.path(dir, "out.json").copy_from(source, mode: :array, columns: %w[a b])
            end

            assert_equal "a,b,c,d\n42,0.125e2,2026-10-13,true\n", IOStreams.path(dir, "out.csv").read
            assert_equal %({"a":42,"b":"0.125e2"}\n), IOStreams.path(dir, "out.json").read
          end
        end

        it "copies typed values into a target without a schema as it writes them without one" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.csv").schema(headerless)
            source.write("0042,12.5,2026-10-13,true\n")
            IOStreams.path(dir, "people.json").copy_from(source, mode: :hash)

            assert_equal %({"id":42,"pay":"0.125e2","joined":"2026-10-13","active":true}\n), IOStreams.path(dir, "people.json").read
          end
        end

        it "is read by #copy_from and #copy_to, whose options only apply to the target" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.csv").schema(headerless)
            source.write("0042,12.5,2026-10-13,true\n")
            IOStreams.path(dir, "people.json").schema(people).copy_from(source, mode: :hash)
            source.copy_to(IOStreams.path(dir, "copy.json").schema(people), mode: :hash)

            expected = %({"id":42,"pay":12.50,"joined":"2026-10-13","active":true}\n)

            assert_equal expected, IOStreams.path(dir, "people.json").read
            assert_equal expected, IOStreams.path(dir, "copy.json").read
          end
        end
      end

      describe "fixed width" do
        let(:fixed) do
          {
            fields: [
              {name: "name", type: "string", width: 6},
              {name: "zip", type: "integer", width: 5, start: 9},
              {name: "pay", type: "number", width: 8, decimals: 2}
            ],
            width:  24
          }
        end

        let(:line) { "Jack  xx12345-0012.50   " }

        it "writes a number that is not finite with spaces, rather than zeros, so that it can be read back" do
          written = write_fixed({"pay" => "NaN"}, {"pay" => "INF"}, {"pay" => "-INF"}, schema: {fields: [{name: "pay", type: "number", width: 8}]})

          assert_equal "     NaN\n     INF\n    -INF\n", written
          pays = read_fixed(written, schema: {fields: [{name: "pay", type: "number", width: 8}]}).map { |record| record["pay"] }

          assert_predicate pays[0], :nan?
          assert_equal [BigDecimal("Infinity"), BigDecimal("-Infinity")], pays[1..]
        end

        # Returns [Array<Hash>] the records read from the text, as a fixed width file, or the rows in the `:array` mode.
        def read_fixed(text, mode = :hash, schema: fixed)
          records = []
          IOStreams::Stream.new(StringIO.new(text)).format(:fixed).schema(schema).each(mode) { |record| records << record }
          records
        end

        # Returns [String] the text written for the records, as a fixed width file.
        def write_fixed(*records, schema: fixed)
          out = StringIO.new
          IOStreams::Stream.new(out).format(:fixed).schema(schema).writer(:hash) do |io|
            records.each { |record| io << record }
          end
          out.string
        end

        it "reads each field at its position, skipping the characters before its start" do
          assert_equal [{"name" => "Jack", "zip" => 12_345, "pay" => BigDecimal("-12.5")}], read_fixed("#{line}\n")
        end

        it "reads each row as the values of the fields, in order, after a header row of the names of the fields" do
          assert_equal [%w[name zip pay], ["Jack", 12_345, BigDecimal("-12.5")], nil], read_fixed("#{line}\n#{' ' * 24}\n", :array)
          assert IOStreams::Stream.new(StringIO.new("#{line}\n")).format(:fixed).schema(fixed).reader(:array, &:header?)
        end

        it "writes the rows that it reads, and copies them into a file with a header row of the names of the fields" do
          Dir.mktmpdir do |dir|
            source = IOStreams.path(dir, "people.fixed").schema(fixed)
            source.write("#{line}\n")
            rows = []
            source.each(:array) { |row| rows << row }
            copy = IOStreams.path(dir, "copy.fixed").schema(fixed)
            copy.writer(:array) { |io| rows.each { |row| io << row } }

            assert_equal "Jack    12345-0012.50   \n", copy.read

            IOStreams.path(dir, "people.csv").copy_from(source, mode: :array)
            IOStreams.path(dir, "again.fixed").schema(fixed).copy_from(source, mode: :array)

            assert_equal "name,zip,pay\nJack,12345,-0.125e2\n", IOStreams.path(dir, "people.csv").read
            assert_equal "Jack    12345-0012.50   \n", IOStreams.path(dir, "again.fixed").read
          end
        end

        it "returns keys that are the names of the fields as they are given" do
          schema = {fields: [{name: :name, width: 4}, {name: "id", type: "integer", width: 2}]}

          assert_equal [{name: "Jack", "id" => 7}], read_fixed("Jack07\n", schema: schema)
        end

        it "raises for a line of another length" do
          assert_raises(IOStreams::Errors::InvalidLineLength) { read_fixed("#{line} \n") }
        end

        it "writes a number right justified and zero filled, and a missing number as zero" do
          assert_equal "Jack    12345-0012.50   \nJill    0000000000.00   \n",
                       write_fixed({"name" => "Jack", "zip" => 12_345, "pay" => BigDecimal("-12.5")}, {name: "Jill"})
        end

        it "raises for a string that is too long, unless its field truncates it" do
          error = assert_raises(IOStreams::Errors::ValueTooLong) { write_fixed({"name" => "Jackson"}) }
          assert_equal "Value: Jackson is too large to fit into column:name of size:6", error.message

          fixed[:fields][0][:truncate] = true

          assert_equal "Jackso  0000000000.00   \n", write_fixed({"name" => "Jackson"})
        end

        it "raises for a number that is too long" do
          assert_raises(IOStreams::Errors::ValueTooLong) { write_fixed({"zip" => 123_456}) }
        end

        it "takes the remainder of the line" do
          schema = {fields: [{name: "id", type: "integer", width: 2}, {name: "note", width: "remainder"}]}

          assert_equal [{"id" => 7, "note" => "any length"}], read_fixed("07any length\n", schema: schema)
          assert_equal "07any length\n", write_fixed({"id" => 7, "note" => "any length"}, schema: schema)
        end

        it "accepts lines of any length with a schema width of remainder" do
          schema = {fields: [{name: "id", type: "integer", width: 2}], width: "remainder"}

          assert_equal [{"id" => 7}, {"id" => 8}], read_fixed("07\n08 and the rest\n", schema: schema)
        end

        it "raises for a field without a width" do
          error = assert_raises(ArgumentError) { read_fixed("Jack\n", schema: {fields: [{name: "name"}]}) }
          assert_equal 'Field "name" needs a width for the :fixed format', error.message
        end

        it "raises for a field that starts within the field before it" do
          schema = {fields: [{name: "a", width: 4}, {name: "b", width: 2, start: 3}]}

          error = assert_raises(ArgumentError) { read_fixed("abcdef\n", schema: schema) }
          assert_equal 'Field "b" starts at 3, within the field before it, which ends at 4', error.message
        end

        it "raises for a field after one that takes the remainder of the line" do
          schema = {fields: [{name: "a", width: "remainder"}, {name: "b", width: 2}]}

          assert_raises(ArgumentError) { read_fixed("abcdef\n", schema: schema) }
        end

        it "raises without a schema or a layout, as before" do
          error = assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new("abc\n")).format(:fixed).each(:hash) { |row| row } }
          assert_match(/missing keyword: :?layout/, error.message)
        end

        it "raises for a schema and the layout of the format options, rather than apply one and ignore the other" do
          path = assert_deprecated(/#format_options is deprecated/) do
            IOStreams::Stream.new(StringIO.new("07\n")).format(:fixed).format_options(layout: [{size: 2, key: :id}]).schema(fixed)
          end

          error = assert_raises(ArgumentError) { path.each(:hash) { |row| row } }
          assert_equal "Supply either schema: or format_options:, not both", error.message
          assert_raises(ArgumentError) { path.writer(:hash) { |io| io } }
        end
      end

      describe "supplied to each call" do
        it "raises for the schema, since it is set on the path" do
          error = assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new(csv)).each(:hash, schema: people) { |row| row } }
          assert_equal ":schema cannot be supplied to each call, set it on the path instead, for example: " \
                       "path.schema(\"people.json\").each(:hash)", error.message

          assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new(csv)).schema(people).each(:array, schema: people) { |row| row } }
          assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new).writer(:hash, schema: people) { |io| io << {"a" => 1} } }
          assert_raises(ArgumentError) { IOStreams::Stream.new(StringIO.new).writer(:line, schema: people) { |io| io << "a" } }
        end

        it "raises when copying with a mode" do
          Dir.mktmpdir do |dir|
            IOStreams.path(dir, "a.csv").write(csv)

            assert_raises(ArgumentError) { IOStreams.path(dir, "b.json").copy_from(IOStreams.path(dir, "a.csv"), mode: :hash, schema: people) }
          end
        end
      end
    end
  end
end
