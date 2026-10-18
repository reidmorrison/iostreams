# frozen_string_literal: true

require_relative "test_helper"
require "json"

class SlicePipelineTest < Minitest::Test
  describe IOStreams::Slice::Pipeline do
    let(:fields) { {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]} }
    let(:schema) { IOStreams.schema(fields) }
    let(:sliced) { IOStreams.sliced.schema(schema) }
    let(:csv) { "Name,AGE\nJack,21\nJill,22\nBob,23\n" }
    let(:people) { [{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}, {"name" => "Bob", "age" => 23}] }

    def slices(data, size: 2, schema: fields, format: nil)
      source = IOStreams.stream(StringIO.new(data)).schema(schema)
      source.format(format) if format
      list = []
      source.each(:slice, size: size) { |slice| list << slice }
      list
    end

    def records(rows, mode = :hash)
      list = []
      rows.each(mode) { |record| list << record }
      list
    end

    describe "#slice" do
      it "parses each slice by the schema and the header row that the slice carries" do
        parsed = slices(csv).flat_map { |slice| records(sliced.slice(slice)) }

        assert_equal people, parsed
      end

      it "parses rows read back from storage, with the header row supplied" do
        rows = sliced.slice(%w[Jill,22 Bob,23], header: %w[Name AGE])

        assert_equal people.drop(1), records(rows)
      end

      it "parses slices whose files have their columns in another order" do
        any_order = IOStreams.sliced.schema(fields.merge("fieldsMatch" => "equal"))
        first     = any_order.slice(["Jack,21"], header: %w[name age])
        second    = any_order.slice(["22,Jill"], header: %w[age name])

        assert_equal [{"name" => "Jack", "age" => 21}], records(first)
        assert_equal [{"name" => "Jill", "age" => 22}], records(second)
      end

      it "matches the header row to the fields once for every slice that shares it" do
        list  = slices(csv, size: 1)
        built = 0
        new   = IOStreams::Tabular.method(:new)
        IOStreams::Tabular.stub(:new, lambda { |**args|
          built += 1
          new.call(**args)
        }) do
          list.each { |slice| records(sliced.slice(slice)) }
        end

        assert_equal 1, built
      end

      it "reads a schema file once, the first time that a slice is parsed" do
        IOStreams.temp_file("slice_pipeline_test", ".json") do |path|
          path.write(JSON.generate(fields))
          pipeline = IOStreams.sliced.schema(path.to_s)
          list     = slices(csv, size: 1)

          assert_equal [people.first], records(pipeline.slice(list.first))
          path.delete

          assert_equal [people.last], records(pipeline.slice(list.last))
        end
      end

      it "reads the rows in the format that the slice carries" do
        fixed = {"fields" => [{"name" => "name", "width" => 4}, {"name" => "age", "type" => "integer", "width" => 2}]}
        list  = slices("Jack21\nJill22\n", schema: fixed, format: :fixed)

        assert_equal :fixed, list.first.format
        assert_equal [{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}],
                     records(IOStreams.sliced.schema(fixed).slice(list.first))
      end

      it "reads rows without a format in the format of the pipeline, otherwise as CSV" do
        json = IOStreams.sliced.schema(fields).format(:json)

        assert_equal [{"name" => "Jack", "age" => 21}], records(json.slice([%({"name":"Jack","age":21})]))
        assert_equal [{"name" => "Jack", "age" => 21}], records(sliced.slice(["Jack,21"], header: %w[name age]))
      end

      it "parses without a schema, by the columns of the header row, cleansed" do
        rows = IOStreams.sliced.slice(slices(csv).first)

        assert_equal [{"name" => "Jack", "age" => "21"}, {"name" => "Jill", "age" => "22"}], records(rows)
      end

      it "raises for a header that is not an Array" do
        assert_raises(ArgumentError) { sliced.slice(["Jack,21"], header: "Name,AGE") }
      end

      it "raises for rows that cannot be read, and a line number that is not a positive Integer" do
        assert_raises(ArgumentError) { sliced.slice(42) }
        assert_raises(ArgumentError) { sliced.slice(["Jack,21"], header: %w[name age], line_number: 0) }
      end
    end

    describe "#format" do
      it "raises for a format that is not registered" do
        assert_raises(ArgumentError) { sliced.format(:unknown) }
      end

      it "takes the name of a format" do
        assert_equal :json, sliced.format("json").format
      end
    end

    describe "#schema" do
      it "returns the schema as it was set" do
        assert_same schema, sliced.schema
        assert_nil IOStreams.sliced.schema
      end

      it "raises for a schema that is not one" do
        assert_raises(ArgumentError) { IOStreams.sliced.schema(42) }
      end
    end
  end

  describe IOStreams::Slice::Rows do
    let(:fields) { {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}, {"name" => "note"}]} }
    let(:sliced) { IOStreams.sliced.schema(fields) }
    # Line 1 and 2 are blank, the header row is on line 3, and Jack's note spans lines 4 and 5.
    let(:csv) { "\n\nName,AGE,Note\nJack,21,\"two\nlines\"\nJill,22,x\n\nBob,abc,y\n" }

    def slice_of(data)
      list = []
      IOStreams.stream(StringIO.new(data)).schema(fields).each(:slice, size: 10) { |slice| list << slice }
      list.first
    end

    def read(rows, mode)
      list = []
      rows.each(mode) { |row| list << row }
      list
    end

    it "gives the line of the file of each row while the block runs" do
      rows  = sliced.slice(slice_of(csv))
      lines = []
      assert_raises(IOStreams::Errors::InvalidValue) { rows.each(:hash) { |_record| lines << rows.line_number } }

      assert_equal [4, 6, 7], lines
    end

    it "raises for a value that is not valid, naming the line of the file that it is on" do
      error = assert_raises(IOStreams::Errors::InvalidValue) { sliced.slice(slice_of(csv)).each(:hash) { |_r| nil } }

      assert_equal 8, error.line_number
      assert_match(/is not a valid integer on line 8\z/, error.message)
    end

    it "does not know the line without the line of the first row" do
      rows = sliced.slice(["Jack,21,x"], header: %w[name age note])

      rows.each(:hash) { |_record| assert_nil rows.line_number }
    end

    it "yields the values of each row in the :array mode, without the header row" do
      rows = sliced.slice(["Jack,21,x", ""], header: %w[name age note])

      assert_equal [["Jack", 21, "x"], nil], read(rows, :array)
    end

    it "yields each row as it is in the :line mode" do
      rows = sliced.slice(["Jack,21,x"], header: %w[name age note])

      assert_equal ["Jack,21,x"], read(rows, :line)
    end

    it "returns the number of rows" do
      assert_equal 2, sliced.slice(["Jack,21,x", "Jill,22,y"], header: %w[name age note]).each(:hash) { |_r| nil }
    end

    it "raises for a mode that it does not read" do
      assert_raises(ArgumentError) { sliced.slice(["Jack,21,x"], header: %w[name age note]).each(:stream) { |_r| nil } }
    end
  end

  describe IOStreams::Slice::Reader do
    let(:fields) { {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}, {"name" => "note"}]} }
    let(:csv) { "\n\nName,AGE,Note\nJack,21,\"two\nlines\"\nJill,22,x\n\nBob,abc,y\n" }

    def slices(data, **)
      list = []
      IOStreams.stream(StringIO.new(data)).schema(fields).each(:slice, **) { |slice| list << slice }
      list
    end

    it "gives each slice the line of its first row, after blank lines and quoted line breaks" do
      assert_equal [4, 7], slices(csv, size: 2).map(&:line_number)
    end

    it "gives each slice the format of its rows" do
      assert_equal [:csv], slices(csv, size: 10).map(&:format)
    end

    it "names the line of a row that is not valid with validate: true" do
      error = assert_raises(IOStreams::Errors::InvalidValue) { slices(csv, size: 10, validate: true) }

      assert_equal 8, error.line_number
    end
  end

  describe IOStreams::Errors::Error do
    it "ends its message with the line that it is on, which is set once" do
      error             = IOStreams::Errors::InvalidValue.new("not valid")
      error.line_number = 12
      error.line_number = 99

      assert_equal 12, error.line_number
      assert_equal "not valid on line 12", error.message
    end

    it "keeps its message without a line" do
      assert_equal "not valid", IOStreams::Errors::InvalidValue.new("not valid").message
    end
  end
end
