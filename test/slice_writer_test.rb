# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SliceWriterTest < Minitest::Test
  describe IOStreams::Slice::Writer do
    let(:csv) { "First Name,AGE\n\"Jack, Jr\",21\n\nJill,22\n" }
    let(:schema) { {"fields" => [{"name" => "first_name"}, {"name" => "age", "type" => "integer"}]} }

    # Returns [Array<IOStreams::Slice>] the slices of the supplied data, read as a file is read, see `#each(:slice)`.
    def slices(data, format: :csv, schema: nil, size: 1)
      source = IOStreams.stream(StringIO.new(data)).format(format)
      source.schema(schema) if schema
      list = []
      source.each(:slice, size: size) { |slice| list << slice }
      list
    end

    # Returns [String] the file that the supplied slices are written to, see `#writer(:slice)`.
    def write(list, format: :csv, schema: nil, **)
      output = StringIO.new
      target = IOStreams.stream(output).format(format)
      target.schema(schema) if schema
      target.writer(:slice, **) do |io|
        list.each { |slice| io << slice }
      end
      output.string
    end

    describe "a slice in the format of the file" do
      it "is written line for line, after the header row as it was read, so that the file is written again" do
        assert_equal csv, write(slices(csv))
      end

      it "matches the header row to the schema, and writes the rows without parsing them" do
        list = slices("first_name,age\nJack,abc\n")

        assert_equal "first_name,age\nJack,abc\n", write(list, schema: schema)
      end

      it "raises InvalidHeader for a header row that does not match the schema, before anything is written" do
        output = StringIO.new
        assert_raises(IOStreams::Errors::InvalidHeader) do
          IOStreams.stream(output).format(:csv).schema(schema).writer(:slice) { |io| io << slices("height\n180\n").first }
        end

        assert_equal "", output.string
      end

      it "writes JSON records as they are" do
        json = %({"a":1}\n{"a":2}\n)

        assert_equal json, write(slices(json, format: :json), format: :json)
      end
    end

    describe "a slice in another format" do
      it "is read by its header row and written in the format of the file, skipping its blank rows" do
        assert_equal %({"First Name":"Jack, Jr","AGE":"21"}\n{"First Name":"Jill","AGE":"22"}\n),
                     write(slices(csv), format: :json)
      end

      it "is read and written by the schema" do
        assert_equal %({"first_name":"Jack, Jr","age":21}\n{"first_name":"Jill","age":22}\n),
                     write(slices(csv), format: :json, schema: schema.merge("fieldsMatch" => "equal"))
      end

      it "writes the header row once" do
        assert_equal "First Name|AGE\nJack, Jr|21\nJill|22\n", write(slices(csv), format: :psv)
      end

      it "writes the keys of JSON records as the header row of CSV" do
        assert_equal "a\n1\n2\n", write(slices(%({"a":1}\n{"a":2}\n), format: :json))
      end
    end

    describe "a slice without a header row" do
      let(:headerless) { schema.merge("header" => false) }

      it "is written line for line to a file without one, keeping its first row" do
        assert_equal "Jack,21\nJill,22\n", write(slices("Jack,21\nJill,22\n", schema: headerless), schema: headerless)
      end

      it "is written after the header row of the schema to a file with one" do
        assert_equal "first_name,age\nJack,21\n", write(slices("Jack,21\n", schema: headerless), schema: schema)
      end

      it "raises without a schema, which would name its columns, before anything is written" do
        %i[csv json].each do |format|
          output = StringIO.new
          error  = assert_raises(ArgumentError) do
            IOStreams.stream(output).format(format).writer(:slice) do |io|
              slices("Jack,21\n", schema: headerless).each { |slice| io << slice }
            end
          end

          assert_equal "The rows written have no header row, and no schema names their columns, as for the rows of " \
                       "the :text format, or a slice without a header row, so the first of them would be the header " \
                       "row of the #{format.inspect} format: set a schema, whose fields name the columns", error.message
          assert_empty output.string
        end
      end

      it "writes every row of an :array slice by the schema, the first one included" do
        array = IOStreams::Slice.new([["Jack", 21], ["Jill", 22]], format: :array)

        assert_equal "first_name,age\nJack,21\nJill,22\n", write([array], schema: schema)
        assert_equal "Jack,21\nJill,22\n", write([array], schema: headerless)
      end
    end

    describe "a slice with a header row" do
      it "is written without it to a file whose schema has none" do
        list = slices("first_name,age\nJack,21\n", schema: schema)

        assert_equal "Jack|21\n", write(list, format: :psv, schema: schema.merge("header" => false))
        assert_equal "Jack,21\n", write(list, schema: schema.merge("header" => false))
      end
    end

    describe "slices of JSON records" do
      it "write the values of every slice in the columns of the first record" do
        list = slices(%({"a":1,"b":2}\n{"b":3,"a":4}\n), format: :json)

        assert_equal "a,b\n1,2\n4,3\n", write(list)
      end

      it "raise InvalidHeader for a key that the first record lacked" do
        list = slices(%({"a":1}\n{"a":3,"b":5}\n), format: :json)

        assert_raises(IOStreams::Errors::InvalidHeader) { write(list) }
      end
    end

    describe "no slices" do
      it "write the header row of the schema" do
        assert_equal "first_name,age\n", write([], schema: schema)
      end

      it "write nothing without a schema, since no slice names the columns" do
        assert_equal "", write([])
      end
    end

    it "writes the header row once when the same slice is written again" do
      slice = slices("a,b\n1,2\n").first

      assert_equal %({"a":"1","b":"2"}\n{"a":"1","b":"2"}\n), write([slice, slice], format: :json)
      assert_equal "a,b\n1,2\n1,2\n", write([slice, slice])
    end

    it "yields the writer of slices supplied to IOStreams.stream, which writes with its own settings" do
      output = StringIO.new
      IOStreams.stream(output).format(:csv).writer(:slice) do |io|
        IOStreams.stream(io).writer(:slice) { |inner| inner << slices("a\n1\n").first }
      end

      assert_equal "a\n1\n", output.string
    end

    describe "validate:" do
      let(:list) { slices("first_name,age\nJack,21\nJill,abc\n") }

      it "parses each row of a slice written as it is, and raises for a value that is not valid" do
        output = StringIO.new
        assert_raises(IOStreams::Errors::InvalidValue) do
          IOStreams.stream(output).format(:csv).schema(schema).writer(:slice, validate: true) do |io|
            list.each { |slice| io << slice }
          end
        end

        assert_equal "first_name,age\nJack,21\n", output.string
      end

      it "does not parse the rows by default" do
        assert_equal "first_name,age\nJack,21\nJill,abc\n", write(list, schema: schema)
      end

      it "raises for a validate that is not true or false" do
        assert_raises(ArgumentError) { write([], validate: "yes") }
      end
    end

    describe "a file" do
      it "keeps what was written, compressed by the streams of its file name" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv.gz")
          path.writer(:slice) do |io|
            slices(csv, size: 2).each { |slice| io << slice }
          end

          assert_equal csv, path.read
        end
      end

      it "is removed when the block raises" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv")
          assert_raises(RuntimeError) do
            path.writer(:slice) do |io|
              io << slices(csv).first
              raise "failed"
            end
          end

          refute_predicate path, :exist?
        end
      end
    end

    it "raises for a slice of another file than the first one written" do
      error = assert_raises(ArgumentError) { write(slices(csv) + slices("x,y\n1,2\n")) }

      assert_match(/\AEvery slice written is of the same file as the first/, error.message)
    end

    it "raises for a slice whose values or blank rows are read otherwise than those of the first one" do
      schema = {"fields" => [{"name" => "wait", "type" => "duration"}]}
      typed  = IOStreams::Slice.new([{"wait" => 300}], format: :hash, schema: schema)
      [IOStreams::Slice.new([{"wait" => "PT5M"}], format: :hash),
       IOStreams::Slice.new([{"wait" => 300}], format: :hash, schema: schema, blank_rows: false)].each do |other|
        error = assert_raises(ArgumentError) do
          IOStreams.stream(StringIO.new).schema(schema).writer(:slice) { |io| io << typed << other }
        end
        assert_equal "Every slice written is of the same file as the first: a slice with the header row nil, format " \
                     ":hash, blank_rows #{other.blank_rows?} and schema #{other.schema&.to_h.inspect} cannot follow one " \
                     "with the header row nil, format :hash, blank_rows true and schema " \
                     "{fields: [{name: \"wait\", type: \"duration\"}]}", error.message
      end
    end

    it "raises for anything but a slice" do
      error = assert_raises(ArgumentError) { write([%w[a b]]) }

      assert_equal "Write an IOStreams::Slice, not a Array", error.message
    end

    it "raises for an option of reading slices" do
      error = assert_raises(ArgumentError) { write([], size: 1) }

      assert_equal ":size only applies when reading, not when writing", error.message
    end

    it "takes the options of the lines" do
      assert_equal "name|Jack|", write(slices("name\nJack\n"), delimiter: "|")
    end
  end
end
