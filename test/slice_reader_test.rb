# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SliceReaderTest < Minitest::Test
  describe IOStreams::Slice::Reader do
    let(:schema) { {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]} }
    let(:csv) { "Name,AGE\nJack,21\nJill,22\nBob,23\n" }

    def stream(data)
      IOStreams.stream(StringIO.new(data))
    end

    def slices(source, **)
      list = []
      source.each(:slice, **) { |slice| list << slice }
      list
    end

    # Returns [Array<Hash>] the records of the slices, each parsed on its own, by the format and header row that it
    # carries, as a worker elsewhere parses it.
    def parse(slices, schema: nil)
      slices.flat_map do |slice|
        tabular = IOStreams::Tabular.new(format: slice.format, schema: schema && IOStreams::Schema.new(schema))
        tabular.read_header(slice.header) if slice.header
        slice.rows.map { |row| tabular.record_parse(row) }
      end
    end

    describe "#each" do
      it "yields the rows as they are in the file, in slices of the size, without the header row" do
        list = slices(stream(csv), size: 2)

        assert_equal [["Jack,21", "Jill,22"], ["Bob,23"]], list.map(&:rows)
        assert(list.all?(IOStreams::Slice))
      end

      it "returns the number of rows read" do
        assert_equal 3, stream(csv).each(:slice, size: 2) { |_slice| nil }
      end

      it "gives each slice the header row of the file, as it was read, which they share, frozen" do
        list = slices(stream(csv), size: 2)

        assert_equal [%w[Name AGE], %w[Name AGE]], list.map(&:header)
        assert_same list.first.header, list.last.header
        assert_predicate list.first.header, :frozen?
        assert(list.first.header.all?(&:frozen?))
      end

      it "gives each slice the format of its rows" do
        assert_equal %i[csv csv], slices(stream(csv), size: 2).map(&:format)
        assert_equal [:psv], slices(stream("name|age\nJack|21\n").format(:psv), size: 2).map(&:format)
      end

      it "gives each slice whether its blank rows are records, which its tabular says" do
        assert_equal [true, true], slices(stream(csv), size: 2).map(&:blank_rows?)

        tabular = IOStreams::Tabular.new(format: :array, blank_rows: false)
        list    = IOStreams::Slice::Reader.new(IOStreams::Slice::Rows.new([%w[name age], [nil, nil]]), tabular: tabular, size: 2).to_a

        assert_equal [[[nil, nil]]], list.map(&:rows)
        refute_predicate list.first, :blank_rows?
      end

      it "yields no slice for a file with a header row and no rows" do
        assert_empty slices(stream("Name,AGE\n"), size: 2)
      end

      it "skips the blank lines before the header row, and keeps those after it as rows" do
        list = slices(stream("\n  \nName,AGE\nJack,21\n\nBob,23\n"), size: 5)

        assert_equal [["Jack,21", "", "Bob,23"]], list.map(&:rows)
        assert_equal %w[Name AGE], list.first.header
      end

      it "gives each slice the line of the file that its first row starts on, and its record number" do
        data = %(\nName,AGE\nJack,"line one\nline two"\n\nJill,22\nBob,23\nAnn,24\n)
        list = slices(stream(data), size: 2)

        assert_equal [3, 6, 8], list.map(&:line_number)
        assert_equal [1, 3, 5], list.map(&:record_number)
      end

      it "gives each row the line of the file that it starts on, and its record number, counting a blank row" do
        data    = %(\nName,AGE\nJack,"line one\nline two"\n\nJill,22\nBob,"a\n\nb"\nAnn,24\n)
        numbers = slices(stream(data), size: 3).map { |slice| slice.each.map { |_row, line, record| [line, record] } }

        assert_equal [[[3, 1], [5, 2], [6, 3]], [[7, 4], [10, 5]]], numbers
      end

      it "gives the rows that are not lines no line, and numbers each one as a record, counting from 1" do
        tabular = IOStreams::Tabular.new(format: :array)
        rows    = [%w[name age], %w[Jack 21], %w[Jill 22], %w[Bob 23]]
        list    = IOStreams::Slice::Reader.new(IOStreams::Slice::Rows.new(rows), tabular: tabular, size: 2).to_a

        assert_equal [nil, nil], list.map(&:line_number)
        assert_equal [1, 3], list.map(&:record_number)
        assert_equal([[nil, 3]], list.last.each.map { |_row, line, record| [line, record] })
      end

      it "gives the rows of a spreadsheet no line, since the lines of the CSV text that it is read as are not its rows" do
        list = slices(IOStreams.path(File.join(__dir__, "files", "multiline_cell.xlsx")), size: 5)

        assert_equal [[%(data 1,data 2,"more\ndata"), nil, 1]], list.first.each.to_a
      end

      it "gives the rows of a compressed file their lines, which are those of the file" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv.gz")
          path.write(%(Name,NOTE\nJack,"line one\nline two"\nJill,22\n))

          assert_equal([[2, 1], [4, 2]], slices(path, size: 5).first.each.map { |_row, line, record| [line, record] })
        end
      end

      it "raises for rows that do not give the line that each one starts on, nor their numbers" do
        error = assert_raises(ArgumentError) do
          IOStreams::Slice::Reader.new([%w[name age]], tabular: IOStreams::Tabular.new(format: :array), size: 2)
        end
        assert_equal "Rows must implement #each_with_line_number, such as IOStreams::Line::Reader, or #each_with_numbers",
                     error.message
      end

      it "keeps a quoted value with a line break within its row" do
        list = slices(stream(%(name,note\nJack,"line one\nline two"\n)), size: 5)

        assert_equal [[%(Jack,"line one\nline two")]], list.map(&:rows)
      end

      it "yields slices that a Tabular with the same schema parses on its own, elsewhere" do
        list = slices(stream(csv).schema(schema), size: 2)

        expected = [{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}, {"name" => "Bob", "age" => 23}]

        assert_equal expected, parse(list, schema: schema)
      end

      it "yields slices that a Tabular parses on its own without a schema" do
        list = slices(stream(csv), size: 2)

        expected = [{"name" => "Jack", "age" => "21"}, {"name" => "Jill", "age" => "22"}, {"name" => "Bob", "age" => "23"}]

        assert_equal expected, parse(list)
      end

      it "gives no header row to the slices of a file without one" do
        list = slices(stream("Jack,21\nJill,22\n").schema(schema.merge("header" => false)), size: 5)

        assert_equal [["Jack,21", "Jill,22"]], list.map(&:rows)
        assert_nil list.first.header
        assert_equal [{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}],
                     parse(list, schema: schema.merge("header" => false))
      end

      it "gives no header row to the slices of a format whose records supply their own keys" do
        list = slices(stream(%({"name":"Jack"}\n{"age":22}\n)).format(:json), size: 5)

        assert_equal [[%({"name":"Jack"}), %({"age":22})]], list.map(&:rows)
        assert_nil list.first.header
        assert_equal :json, list.first.format
        assert_equal [{"name" => "Jack"}, {"age" => 22}], parse(list)
      end

      it "reads a fixed width file by the position of each field of its schema" do
        fixed = {"fields" => [{"name" => "name", "width" => 4}, {"name" => "age", "type" => "integer", "width" => 2}]}
        list  = slices(stream("Jack21\nJill22\n").format(:fixed).schema(fixed), size: 5)

        assert_equal [%w[Jack21 Jill22]], list.map(&:rows)
        assert_equal [{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}], parse(list, schema: fixed)
      end
    end

    describe "the header row" do
      it "raises InvalidHeader for a header row that does not match the schema, before the first slice" do
        source = stream("name,age,extra\nJack,21,x\n").schema(schema.merge("fieldsMatch" => "equal"))

        assert_raises(IOStreams::Errors::InvalidHeader) { source.each(:slice, size: 2) { |_slice| flunk("yielded") } }
      end

      it "raises InvalidHeader for a header row without a required field" do
        required = {"fields" => [{"name" => "name", "constraints" => {"required" => true}}, {"name" => "age"}]}

        assert_raises(IOStreams::Errors::InvalidHeader) { slices(stream("age\n21\n").schema(required), size: 2) }
      end

      it "is held by the reader once it is read, also when the file has no rows" do
        header = stream("Name,AGE\n").reader(:slice, size: 2) do |reader|
          reader.each { |_slice| nil }
          reader.header
        end

        assert_equal %w[Name AGE], header
      end
    end

    describe "the keys of the first record" do
      let(:equal) { schema.merge("fieldsMatch" => "equal") }

      it "are matched to the fields of the schema before the first slice, for a format of keyed records" do
        source = stream(%({"x":1}\n)).format(:json).schema(equal)

        assert_raises(IOStreams::Errors::InvalidHeader) { source.each(:slice, size: 2) { |_slice| flunk("yielded") } }
      end

      it "are those of the first record that is not blank, without converting its values" do
        list = slices(stream(%(\n{"name":"Jack","age":"abc"}\n)).format(:json).schema(equal), size: 5)

        assert_equal [["", %({"name":"Jack","age":"abc"})]], list.map(&:rows)
      end

      it "are only those of the first record, since the keys of the others are matched where they are parsed" do
        list = slices(stream(%({"name":"Jack","age":21}\n{"x":1}\n)).format(:json).schema(equal), size: 5)

        assert_equal [[%({"name":"Jack","age":21}), %({"x":1})]], list.map(&:rows)
      end
    end

    describe "validate:" do
      let(:invalid) { "name,age\nJack,21\nJill,abc\n" }

      it "parses each row, and raises for a value that is not valid" do
        assert_raises(IOStreams::Errors::InvalidValue) { slices(stream(invalid).schema(schema), size: 1, validate: true) }
      end

      it "has already yielded the slices before the row that is not valid" do
        list = []
        assert_raises(IOStreams::Errors::InvalidValue) do
          stream(invalid).schema(schema).each(:slice, size: 1, validate: true) { |slice| list << slice }
        end

        assert_equal [["Jack,21"]], list.map(&:rows)
      end

      it "still yields the rows as they are in the file" do
        assert_equal [["Jack,21"]], slices(stream("name,age\nJack,21\n").schema(schema), size: 1, validate: true).map(&:rows)
      end

      it "does not parse the rows by default" do
        assert_equal [["Jack,21", "Jill,abc"]], slices(stream(invalid).schema(schema), size: 2).map(&:rows)
      end
    end

    describe "options" do
      it "raises for a size that is not a positive Integer" do
        [0, -1, 1.5, "2", nil].each do |size|
          assert_raises(ArgumentError) { slices(stream(csv), size: size) }
        end
      end

      it "raises without a size" do
        assert_raises(ArgumentError) { slices(stream(csv)) }
      end

      it "raises for a validate that is not true or false" do
        assert_raises(ArgumentError) { slices(stream(csv), size: 2, validate: "yes") }
      end

      it "checks the options before the file is opened" do
        path = IOStreams.path("/nonexistent/people.csv")

        assert_raises(ArgumentError) { path.each(:slice, size: 0) { |_slice| nil } }
        assert_raises(ArgumentError) { path.each(:slice, size: 2, validate: "yes") { |_slice| nil } }
        assert_raises(ArgumentError) { path.each(:slice, size: 2, columns: %w[name age]) { |_slice| nil } }
      end

      it "raises for the column options, which v3.0 removed, as options that the mode does not take" do
        %i[columns allowed_columns required_columns skip_unknown cleanse_header].each do |name|
          error = assert_raises(ArgumentError) { slices(stream(csv), size: 2, name => nil) }
          assert_match(/\AUnknown option #{name.inspect} for the :slice mode/, error.message)
        end
      end

      it "lists the options of the mode" do
        error = assert_raises(ArgumentError) { slices(stream(csv), size: 2, unknown: 1) }
        assert_match(/Valid options: :delimiter, :buffer_size, :size, :validate\.\z/, error.message)
      end

      it "raises for a setting that describes the file, which is set on the path" do
        error = assert_raises(ArgumentError) { slices(stream(csv), size: 2, schema: schema) }
        assert_match(/set it on the path instead/, error.message)
      end

      it "takes the options of the lines" do
        assert_equal [%w[Jack,21 Jill,22]], slices(stream("name,age|Jack,21|Jill,22"), size: 5, delimiter: "|").map(&:rows)
      end

      it "are read options, which a writer rejects" do
        error = assert_raises(ArgumentError) { IOStreams.stream(StringIO.new).writer(:line, size: 2) { |_writer| nil } }
        assert_match(/:size only applies when reading/, error.message)
      end
    end
  end

  describe IOStreams::Slice do
    it "holds the rows, with the header row and format" do
      slice = IOStreams::Slice.new(%w[a b], header: %w[name].freeze, format: :csv)

      assert_equal %w[a b], slice.rows
      assert_equal %w[name], slice.header
      assert_equal :csv, slice.format
    end

    it "has no header row nor format by default, and its blank rows are blank rows, as in a file" do
      assert_nil IOStreams::Slice.new.header
      assert_nil IOStreams::Slice.new.format
      assert_predicate IOStreams::Slice.new, :blank_rows?
    end
  end
end
