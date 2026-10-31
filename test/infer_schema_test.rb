# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"

class InferSchemaTest < Minitest::Test
  describe IOStreams::Stream do
    describe "#infer_schema" do
      # Returns [IOStreams::Stream] a stream of the text, read as the file name says.
      def text(text, file_name)
        IOStreams.stream(StringIO.new(text)).file_name(file_name)
      end

      # Returns [Array<Hash>] the fields of the schema that the stream infers, as Hashes.
      def fields(stream)
        stream.infer_schema.to_h[:fields]
      end

      it "returns the schema that was set, as a schema" do
        stream = text("id\n1\n", "orders.csv").schema(fields: [{name: "id", type: "integer"}])

        assert_instance_of IOStreams::Schema, stream.infer_schema
        assert_equal({fields: [{name: "id", type: "integer"}]}, stream.infer_schema.to_h)
      end

      it "reads the schema that was set from its file" do
        Dir.mktmpdir do |dir|
          IOStreams.path(dir, "orders.json").write(%({"fields":[{"name":"id","type":"integer"}]}))
          stream = text("id\n1\n", "orders.csv").schema(File.join(dir, "orders.json"))

          assert_equal [{name: "id", type: "integer"}], fields(stream)
        end
      end

      it "names a field of type string for each column of the header row of CSV, as each(:hash) keys its records" do
        csv  = "ID,Amount,Ordered At,Zip\n1001,12.50,2026-10-25T09:30:00Z,01234\n"
        keys = nil
        text(csv, "orders.csv").each(:hash) { |record| keys = record.keys }

        assert_equal [{name: "id", type: "string"}, {name: "amount", type: "string"},
                      {name: "ordered_at", type: "string"}, {name: "zip", type: "string"}], fields(text(csv, "orders.csv"))
        assert_equal(keys, fields(text(csv, "orders.csv")).map { |field| field[:name] })
      end

      it "reads only the header row, so that a value in a later row cannot change it" do
        stream = text("id,name\n1,\"not closed\n", "orders.csv")

        assert_equal(%w[id name], fields(stream).map { |field| field[:name] })
      end

      it "skips blank lines before the header row, as reading does" do
        assert_equal(%w[a b], fields(text("\n\nA,B\n1,2\n", "orders.csv")).map { |field| field[:name] })
      end

      it "names the fields of PSV by its header row too" do
        assert_equal [{name: "id", type: "string"}, {name: "name", type: "string"}], fields(text("Id|Name\n1|Jack\n", "people.psv"))
      end

      it "leaves out a column whose name cleanses to nothing, as each(:hash) leaves it out" do
        assert_equal(%w[id name], fields(text("id,#,name\n1,2,3\n", "orders.csv")).map { |field| field[:name] })
      end

      it "reads the file that it describes, past the columns and keys without a name that it leaves out" do
        [["id,#,name\n1,2,3\n", "orders.csv"], ["id,,name\n1,2,3\n", "orders.csv"], ["id,name,\n1,3,\n", "orders.csv"],
         [%({"":2,"id":"1","name":"3"}\n), "orders.json"]].each do |data, file_name|
          schema  = text(data, file_name).infer_schema
          records = []
          text(data, file_name).schema(schema).each(:hash) { |record| records << record }

          assert_equal "subset", schema.fields_match, data
          assert_equal [{"id" => "1", "name" => "3"}], records, data
        end
        assert_equal "exact", text("id,name\n1,3\n", "orders.csv").infer_schema.fields_match
      end

      it "returns an IO that it reads to where it was, so that its rows are still read" do
        io = StringIO.new("id,name\n1,Jack\n")
        io.gets
        stream = IOStreams.stream(io).file_name("people.csv")
        stream.infer_schema
        records = []
        stream.each(:array) { |row| records << row }

        assert_equal [%w[1 Jack]], records
      end

      it "raises for two columns that are the same key once cleansed, since a schema cannot hold both" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) { text("Amount ($),Amount (€)\n1,2\n", "orders.csv").infer_schema }

        assert_includes error.message, '"Amount ($)" and "Amount (€)"'
        assert_includes error.message, '"amount_"'
      end

      it "names a field of type any for each key of the first JSON record, each of whose values has its own type" do
        stream = text(%({"id":1001,"Ordered At":"2026-10-25"}\n{"id":1002,"zip":"01234"}\n), "orders.json")

        assert_equal [{name: "id", type: "any"}, {name: "Ordered At", type: "any"}], fields(stream)
      end

      it "has no fields for a file without rows" do
        assert_equal [], fields(text("", "orders.csv"))
        assert_equal [], fields(text("\n", "orders.json"))
      end

      it "names the fields of a spreadsheet by its header row, of type any, since each cell has its own type" do
        assert_equal [{name: "first_column", type: "any"}, {name: "second_column", type: "any"},
                      {name: "third_column", type: "any"}], fields(IOStreams.path(File.join(__dir__, "files", "spreadsheet.xlsx")))
      end

      it "names the fields of a slice by its header row" do
        slice = IOStreams::Slice.new([%w[1 2]], header: ["First Name", "Zip"], format: :csv)

        assert_equal [{name: "first_name", type: "string"}, {name: "zip", type: "string"}], fields(IOStreams.stream(slice))
      end

      it "raises for a fixed width file, which declares neither the names nor the positions of its columns" do
        error = assert_raises(ArgumentError) { text("1001\n", "orders.fixed").infer_schema }

        assert_includes error.message, "needs a schema"
      end

      it "raises for the :text format, whose one column has no name" do
        assert_raises(ArgumentError) { text("a\n", "orders.text").infer_schema }
      end

      it "raises ArgumentError for an argument that it does not take" do
        assert_raises(ArgumentError) { text("id\n1\n", "orders.csv").infer_schema(rows: 10) }
      end

      describe "Parquet" do
        before do
          skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)
        end

        it "returns the type of each column, read from the end of the file, and requires a column that cannot be null" do
          Dir.mktmpdir do |dir|
            schema = {
              fields: [
                {name: "id", type: "integer", constraints: {required: true}},
                {name: "amount", type: "number", decimals: 2},
                {name: "ratio", type: "number", floatNumber: true},
                {name: "ordered_at", type: "datetime"},
                {name: "shipped_on", type: "date"},
                {name: "opens", type: "time"},
                {name: "zip", type: "string", constraints: {required: true}, allowBlank: true},
                {name: "paid", type: "boolean"},
                {name: "data", type: "object"}
              ]
            }
            path = IOStreams.path(dir, "orders.parquet")
            path.schema(schema).writer(:hash) { |io| io << {"id" => 1, "zip" => ""} }

            expected = [
              {name: "id", type: "integer", constraints: {required: true}},
              {name: "amount", type: "number", decimals: 2},
              {name: "ratio", type: "number", floatNumber: true},
              {name: "ordered_at", type: "datetime"},
              {name: "shipped_on", type: "date"},
              {name: "opens", type: "time"},
              # Text can be empty, so a column of it that cannot be null is not required, as for a query.
              {name: "zip", type: "string"},
              {name: "paid", type: "boolean"},
              # Written as its JSON text, which the file declares as a string.
              {name: "data", type: "string"}
            ]

            assert_equal expected, fields(IOStreams.path(dir, "orders.parquet"))
          end
        end

        it "raises for an encoding, as reading does, rather than decode the bytes of the file" do
          Dir.mktmpdir do |dir|
            IOStreams.path(dir, "orders.parquet").schema(fields: [{name: "id", type: "integer"}]).writer(:hash) { |io| io << {"id" => 1} }
            error = assert_raises(ArgumentError) { IOStreams.path(dir, "orders.parquet").encoding("UTF-8").infer_schema }

            assert_includes error.message, "#encoding cannot be used with the :parquet format"
          end
        end

        it "returns the fields of a file without rows" do
          Dir.mktmpdir do |dir|
            IOStreams.path(dir, "orders.parquet").schema(fields: [{name: "id", type: "integer"}]).writer(:hash) { |_io| nil }

            assert_equal [{name: "id", type: "integer"}], fields(IOStreams.path(dir, "orders.parquet"))
          end
        end

        it "returns the type of the values of nested and other columns that the parquet gem writes" do
          Dir.mktmpdir do |dir|
            file = File.join(dir, "nested.parquet")
            require "parquet"
            schema = ::Parquet::Schema.define do
              field :list, :list, item: :int32
              field :map, :map, key: :string, value: :int32
              field :struct, :struct do
                field :a, :int32
              end
              field :small, :int8
              field :ratio, :float
              field :at, :timestamp_millis
              field :bytes, :binary
            end
            ::Parquet.write_rows([[[1], {"a" => 1}, {"a" => 1}, 1, 1.5, Time.now, "x".b]].each, schema: schema, write_to: file)

            assert_equal [{name: "list", type: "array"}, {name: "map", type: "object"}, {name: "struct", type: "object"},
                          {name: "small", type: "integer"}, {name: "ratio", type: "number", floatNumber: true},
                          {name: "at", type: "datetime"}, {name: "bytes", type: "any"}], fields(IOStreams.path(file))
          end
        end
      end
    end
  end
end
