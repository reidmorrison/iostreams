# frozen_string_literal: true

require_relative "test_helper"

class RowReaderTest < Minitest::Test
  describe IOStreams::Row::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "test.csv")
    end

    let :expected do
      CSV.read(file_name)
    end

    describe "#each" do
      it "file" do
        rows  = []
        count = IOStreams.path(file_name).reader(:array) do |io|
          io.each { |row| rows << row }
        end

        assert_equal expected, rows
        assert_equal expected.size, count
      end

      it "stream" do
        rows  = []
        count = File.open(file_name) do |file|
          IOStreams.stream(file).reader(:array) do |io|
            io.each { |row| rows << row }
          end
        end

        assert_equal expected, rows
        assert_equal expected.size, count
      end

      it "keeps newlines within quoted values when reading a file" do
        embedded_file_name = File.join(File.dirname(__FILE__), "files", "embedded_lines_test.csv")
        rows               = []
        IOStreams.path(embedded_file_name).each(:array) { |row| rows << row }

        assert_equal CSV.read(embedded_file_name), rows
      end

      it "yields the header row as an IOStreams::Row::HeaderRow, and each other row as an Array" do
        rows = []
        IOStreams.stream(StringIO.new("name,zip\nJack,1\n")).each(:array) { |row| rows << row }

        assert_equal [%w[name zip], %w[Jack 1]], rows
        assert_instance_of IOStreams::Row::HeaderRow, rows.first
        assert_instance_of Array, rows.last
      end

      it "yields the keys of the first record of JSON without a schema as an IOStreams::Row::HeaderRow" do
        rows = []
        IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).format(:json).each(:array) { |row| rows << row }

        assert_equal [%w[name], %w[Jack]], rows
        assert_instance_of IOStreams::Row::HeaderRow, rows.first
      end

      it "yields the names of the fields of the header row read with a schema as an IOStreams::Row::HeaderRow" do
        rows   = []
        schema = {fields: [{name: "name"}, {name: "zip"}], fieldsMatch: "equal"}
        IOStreams.stream(StringIO.new("Zip,Name\n1,Jack\n")).schema(schema).each(:array) { |row| rows << row }

        assert_equal [%w[name zip], %w[Jack 1]], rows
        assert_instance_of IOStreams::Row::HeaderRow, rows.first
      end

      describe "a file without a header row" do
        let(:fixed) { {fields: [{name: "name", width: 4}, {name: "zip", type: "integer", width: 5}]} }

        # Returns [Array] the rows read from the fixed width text.
        def read_fixed(text)
          rows = []
          IOStreams.stream(StringIO.new(text)).format(:fixed).schema(fixed).each(:array) { |row| rows << row }
          rows
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
            IOStreams.stream(StringIO.new("Jack12345\n")).format(:fixed).schema(fixed).each(:array) { |row| io << row }
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

    describe "#header?" do
      it "is true when the first row is the header row of the file, the names of the fields of a file without one, or the keys of the first record of JSON without a schema" do
        assert IOStreams.stream(StringIO.new("name\nJack\n")).reader(:array, &:header?)
        assert IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).format(:json).reader(:array, &:header?)
        assert IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).format(:json).schema(fields: [{name: "name"}]).reader(:array, &:header?)
        assert IOStreams.stream(StringIO.new("Jack\n")).schema(header: false, fields: [{name: "name"}]).reader(:array, &:header?)
      end
    end

    describe "the rows of JSON without a schema" do
      # Returns [Array] the rows read from the JSON text.
      def read_json(json, **)
        rows = []
        IOStreams.stream(StringIO.new(json)).format(:json).each(:array, **) { |row| rows << row }
        rows
      end

      it "start with a header row of the keys of the first record, then hold the values of each record in that order" do
        json = %({"name":"Jack","tags":["a"],"address":{"zip":"12345"}}\n{"address":null,"tags":[],"name":"Jill"}\n)

        assert_equal [%w[name tags address], ["Jack", ["a"], {"zip" => "12345"}], ["Jill", [], nil]], read_json(json)
      end

      it "hold nil for a key that a record does not have" do
        assert_equal [%w[name age], ["Jack", 21], ["Jill", nil]], read_json(%({"name":"Jack","age":21}\n{"name":"Jill"}\n))
      end

      it "start with a header row of its own, so that changing it does not change the columns of the rows after it" do
        rows = []
        IOStreams.stream(StringIO.new(%({"name":"Jack"}\n{"name":"Jill"}\n))).format(:json).each(:array) do |row|
          rows << row.map(&:dup)
          row.each(&:upcase!)
        end

        assert_equal [%w[name], %w[Jack], %w[Jill]], rows
      end

      it "are nil for a blank line, a line of null, or a record without keys, which do not give the columns" do
        assert_equal [nil, nil, nil, %w[a], [1], nil], read_json(%(\nnull\n{}\n{"a":1}\n{}\n))
      end

      it "raise for a record with a key that the first record does not have, since no row has a column for it" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) { read_json(%({"name":"Jack"}\n{"name":"Jill","age":22,"zip":1}\n)) }
        assert_equal "The keys of a record do not match the columns of the rows, which are the keys of the first record: the " \
                     'keys "age" and "zip" are not among them. Read the records with each(:hash), or describe the columns with a ' \
                     'schema whose fields are every key, with fieldsMatch "superset" when a record can leave out a key',
                     error.message
      end

      it "raise for a line that is not an object" do
        ["[1,2]", "5", %("x"), "true"].each do |line|
          assert_raises(IOStreams::Errors::TypeMismatch, line) { read_json(%({"a":1}\n#{line}\n)) }
        end
      end
    end

    describe "#collect" do
      it "is Enumerable, as a reader of records is" do
        csv = "name,zip\nJack,12345\nJill,23456\n"

        assert_equal %w[name Jack Jill], IOStreams.stream(StringIO.new(csv)).reader(:array) { |io| io.collect(&:first) }
        assert_equal [%w[name zip], %w[Jack 12345]], IOStreams.stream(StringIO.new(csv)).reader(:array) { |io| io.first(2) }
      end

      it "returns an Enumerator of the rows from #each without a block" do
        csv  = "name,zip\nJack,12345\n\nJill,23456\n"
        rows = IOStreams.stream(StringIO.new(csv)).reader(:array) { |io| io.each.with_index.to_a }
        kept = IOStreams.stream(StringIO.new(csv)).reader(:array, skip_blanks: true) { |io| io.each.to_a }

        assert_equal [[%w[name zip], 0], [%w[Jack 12345], 1], [nil, 2], [%w[Jill 23456], 3]], rows
        assert_equal [%w[name zip], %w[Jack 12345], %w[Jill 23456]], kept
      end
    end

    describe "#inspect" do
      it "shows the class and the format of the rows, rather than the objects that it reads them with" do
        assert_equal "#<IOStreams::Row::Reader format=:csv>", IOStreams.path(file_name).reader(:array, &:inspect)
        assert_equal "#<IOStreams::Row::Reader format=:json>",
                     IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).format(:json).reader(:array, &:inspect)
      end
    end
  end
end
