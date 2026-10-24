# frozen_string_literal: true

require_relative "test_helper"
require "json"

class SliceTest < Minitest::Test
  describe IOStreams::Slice do
    let(:schema) { {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]} }
    let(:slice) { IOStreams::Slice.new(["Jack,21", %("Ji\nll",22)], header: %w[Name AGE].freeze, format: :csv) }

    def slices(data, **)
      list = []
      IOStreams.stream(StringIO.new(data)).schema(schema).each(:slice, size: 2, **) { |slice| list << slice }
      list
    end

    describe "#to_h" do
      it "holds the rows, the header row and the format, by String keys, with Strings, Arrays and nil" do
        assert_equal({"rows" => ["Jack,21", %("Ji\nll",22)], "header" => %w[Name AGE], "format" => "csv"}, slice.to_h)
      end

      it "holds nil for a slice without a header row or format" do
        assert_equal({"rows" => %w[a], "header" => nil, "format" => nil}, IOStreams::Slice.new(%w[a]).to_h)
      end

      it "holds its rows in an Array of their own, so that changing it does not change the slice" do
        slice.to_h["rows"] << "Bob,23"

        assert_equal 2, slice.size
        assert_instance_of Array, slice.to_h["rows"]
      end

      it "holds blank_rows: false for a slice whose every row is a record, such as the rows of a query" do
        records = IOStreams::Slice.new([[nil, nil]], header: %w[name age].freeze, format: :array, blank_rows: false)

        assert_equal({"rows" => [[nil, nil]], "header" => %w[name age], "format" => "array", "blank_rows" => false}, records.to_h)
      end

      it "holds the line that the first row starts on, when the slice has one" do
        numbered = IOStreams::Slice.new(%w[a], format: :csv, line_number: 7)

        assert_equal({"rows" => %w[a], "header" => nil, "format" => "csv", "line_number" => 7}, numbered.to_h)
      end
    end

    describe "IOStreams.slice" do
      it "turns the Hash of a slice back into the slice" do
        copy = IOStreams.slice(slice.to_h)

        assert_instance_of IOStreams::Slice, copy
        assert_equal slice, copy
        assert_equal %w[Name AGE], copy.header
        assert_equal :csv, copy.format
      end

      it "reads the Hash as JSON keeps it, with a quoted line break and text that is not ASCII" do
        slice = IOStreams::Slice.new(["José,21", %("Ji\r\nll",22)], header: ["Name", nil, "AGE"], format: :csv)
        copy  = IOStreams.slice(JSON.parse(JSON.generate(slice.to_h)))

        assert_equal slice, copy
        assert_equal ["Name", nil, "AGE"], copy.header
        assert_equal :csv, copy.format
      end

      it "reads the Hash with Symbol keys and a Symbol format" do
        copy = IOStreams.slice(rows: %w[a], header: %w[name], format: :psv)

        assert_equal %w[a], copy
        assert_equal :psv, copy.format
      end

      it "gives the slice a frozen copy of the header row, as the slices of a file share it" do
        header = [+"Name", +"AGE"]
        copy   = IOStreams.slice("rows" => [], "header" => header, "format" => "csv")

        assert_predicate copy.header, :frozen?
        assert(copy.header.all?(&:frozen?))
        refute(header.any?(&:frozen?))
      end

      it "reads a slice without a header row or format" do
        copy = IOStreams.slice("rows" => %w[a])

        assert_nil copy.header
        assert_nil copy.format
        assert_predicate copy, :blank_rows?
      end

      it "turns back a slice whose every row is a record, once stored as JSON, or with a Symbol key" do
        records = IOStreams::Slice.new([[nil, nil]], header: %w[name age].freeze, format: :array, blank_rows: false)

        refute_predicate IOStreams.slice(JSON.parse(JSON.generate(records.to_h))), :blank_rows?
        refute_predicate IOStreams.slice(rows: [], blank_rows: false), :blank_rows?
        assert_predicate IOStreams.slice(rows: [], blank_rows: true), :blank_rows?
      end

      it "turns back the slices that a file was read in, whose rows a Tabular parses by what each one carries" do
        stored  = slices("Name,AGE\nJack,21\nJill,22\nBob,23\n").map { |slice| JSON.generate(slice.to_h) }
        records = stored.flat_map do |json|
          slice   = IOStreams.slice(JSON.parse(json))
          tabular = IOStreams::Tabular.new(format: slice.format, schema: IOStreams::Schema.new(schema))
          tabular.read_header(slice.header)
          slice.map { |row| tabular.record_parse(row) }
        end

        assert_equal [{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}, {"name" => "Bob", "age" => 23}], records
      end

      it "raises for anything other than a Hash" do
        error = assert_raises(ArgumentError) { IOStreams.slice(%w[a]) }
        assert_match(/must be the Hash that #to_h returns, not Array/, error.message)
      end

      it "raises for a Hash without rows, or whose rows are not an Array" do
        assert_raises(ArgumentError) { IOStreams.slice("header" => nil) }
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => "Jack,21") }
        assert_match(/rows of a slice must be an Array, not String/, error.message)
      end

      it "raises for a key that a slice does not have" do
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "line" => 1) }
        assert_equal 'Unknown key "line" of a slice. Valid keys: "rows", "header", "format", "blank_rows", "line_number"',
                     error.message
      end

      it "turns back the line that the first row starts on, once stored as JSON, or nil for a Hash without one" do
        numbered = IOStreams::Slice.new(%w[a], format: :csv, line_number: 7)

        assert_equal 7, IOStreams.slice(JSON.parse(JSON.generate(numbered.to_h))).line_number
        assert_equal 7, IOStreams.slice(rows: [], line_number: 7).line_number
        assert_nil IOStreams.slice("rows" => %w[a]).line_number
      end

      it "turns back the lines of the slices that a file was read in" do
        stored = slices("Name,AGE\nJack,21\nJill,22\nBob,23\n").map { |slice| JSON.generate(slice.to_h) }

        assert_equal([2, 4], stored.map { |json| IOStreams.slice(JSON.parse(json)).line_number })
      end

      it "raises for a line_number that is not a positive Integer" do
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "line_number" => "2") }
        assert_equal 'The line_number of a slice must be a positive Integer: "2"', error.message
        assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "line_number" => 0) }
      end

      it "raises for a blank_rows that is not true or false" do
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "blank_rows" => "false") }
        assert_equal 'The blank_rows of a slice must be true or false: "false"', error.message
      end

      it "raises for a header row that is not an Array of Strings" do
        assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "header" => "Name,AGE") }
        assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "header" => [1, 2]) }
      end

      it "raises for a format that is not a tabular format" do
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "format" => "gz") }
        assert_match(/\AUnknown format of a slice: "gz"\. Valid formats: /, error.message)
        assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "format" => 1) }
      end
    end
  end
end
