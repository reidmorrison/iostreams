# frozen_string_literal: true

require_relative "test_helper"
require "logger"

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
    end

    describe "#header?" do
      it "is true when the first row is the header row of the file, or the keys of the first record of JSON without a schema" do
        assert IOStreams.stream(StringIO.new("name\nJack\n")).reader(:array, &:header?)
        assert IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).format(:json).reader(:array, &:header?)
        refute IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).format(:json).schema(fields: [{name: "name"}]).reader(:array, &:header?)
        refute IOStreams.stream(StringIO.new("Jack\n")).schema(header: false, fields: [{name: "name"}]).reader(:array, &:header?)
        refute(assert_deprecated(/describe the columns of the file with #schema instead/) do
          IOStreams.stream(StringIO.new(%({"name":"Jack"}\n))).format(:json).reader(:array, columns: %w[name], &:header?)
        end)
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
    end

    describe "allowed and required columns" do
      allow_deprecation(/describe the columns of the file with #schema instead/)

      let(:csv) { "Name,Secret\nJack,x\n" }

      def read_rows(**args)
        rows = []
        IOStreams.stream(StringIO.new(csv)).each(:array, **args) { |row| rows << row }
        rows
      end

      it "applies required columns to the header row" do
        assert_raises(IOStreams::Errors::InvalidHeader) { read_rows(required_columns: ["missing"]) }
      end

      it "applies required columns to the header row when cleanse_header is false" do
        assert_raises(IOStreams::Errors::InvalidHeader) { read_rows(required_columns: ["missing"], cleanse_header: false) }
      end

      it "compares the header row as-is when cleanse_header is false" do
        rows = read_rows(required_columns: ["Name"], cleanse_header: false)

        assert_equal [%w[Name Secret], %w[Jack x]], rows
      end

      it "applies allowed columns to supplied columns" do
        assert_raises(IOStreams::Errors::InvalidHeader) do
          read_rows(columns: %w[name secret], allowed_columns: ["name"], skip_unknown: false)
        end
      end

      it "applies required columns to supplied columns" do
        assert_raises(IOStreams::Errors::InvalidHeader) do
          read_rows(columns: %w[name secret], required_columns: ["missing"])
        end
      end

      it "yields the header row as read" do
        rows = read_rows(allowed_columns: ["name"])

        assert_equal [%w[Name Secret], %w[Jack x]], rows
      end

      # Returns [Array] the rows read from the JSON text.
      def read_json_rows(json, **args)
        rows = []
        IOStreams.stream(StringIO.new(json)).format(:json).each(:array, **args) { |row| rows << row }
        rows
      end

      it "applies them to the keys of the first record of JSON, which the header row holds as they are, as each row holds every value" do
        json = %({"Name":"Jack","Secret":"x"}\n)

        assert_equal [%w[Name Secret], %w[Jack x]], read_json_rows(json, allowed_columns: ["name"])
        assert_equal [%w[Name Secret], %w[Jack x]], read_json_rows(json, required_columns: ["Name"], cleanse_header: false)
        assert_raises(IOStreams::Errors::InvalidHeader) { read_json_rows(json, allowed_columns: ["name"], skip_unknown: false) }
        assert_raises(IOStreams::Errors::InvalidHeader) { read_json_rows(json, required_columns: ["missing"]) }
      end

      it "reads the values of the columns supplied from the keys of JSON, or the keys that are the same once cleansed, without a header row" do
        assert_equal [%w[Jack x]], read_json_rows(%({"name":"Jack","Secret":"x","admin":true}\n), columns: %w[Name secret])
        assert_equal [["Jack", nil]], read_json_rows(%({"name":"Jack"}\n), columns: %w[name secret], allowed_columns: %w[name])
      end

      describe "when enforce_column_restrictions is false" do
        # Returns [Array] the rows read, and the warnings logged.
        def read_with_warnings(**args)
          output   = StringIO.new
          original = IOStreams.logger
          IOStreams.logger = Logger.new(output, level: :warn)
          rows = read_rows(**args)
          [rows, output.string.lines.grep(/enforce_column_restrictions/).size]
        ensure
          IOStreams.logger = original
        end

        before do
          IOStreams.enforce_column_restrictions = false
        end

        after do
          IOStreams.enforce_column_restrictions = true
        end

        it "still applies required columns to the header row by default" do
          assert_raises(IOStreams::Errors::InvalidHeader) { read_rows(required_columns: ["missing"]) }
        end

        it "warns instead of applying them with cleanse_header: false" do
          rows, warnings = read_with_warnings(required_columns: ["missing"], cleanse_header: false)

          assert_equal [%w[Name Secret], %w[Jack x]], rows
          assert_equal 1, warnings
        end

        it "warns instead of applying them to supplied columns" do
          rows, warnings = read_with_warnings(columns: %w[name secret], allowed_columns: ["name"], skip_unknown: false)

          assert_equal [%w[Name Secret], %w[Jack x]], rows
          assert_equal 1, warnings
        end

        it "does not warn when they would not change the columns" do
          _rows, warnings = read_with_warnings(columns: %w[name secret], allowed_columns: %w[name secret])

          assert_equal 0, warnings
        end
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
