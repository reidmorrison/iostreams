# frozen_string_literal: true

require_relative "test_helper"

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
        slice.map { |row| tabular.record_parse(row) }
      end
    end

    describe "#each" do
      it "yields the rows as they are in the file, in slices of the size, without the header row" do
        list = slices(stream(csv), size: 2)

        assert_equal [["Jack,21", "Jill,22"], ["Bob,23"]], list
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

      it "yields no slice for a file with a header row and no rows" do
        assert_empty slices(stream("Name,AGE\n"), size: 2)
      end

      it "skips the blank lines before the header row, and keeps those after it as rows" do
        list = slices(stream("\n  \nName,AGE\nJack,21\n\nBob,23\n"), size: 5)

        assert_equal [["Jack,21", "", "Bob,23"]], list
        assert_equal %w[Name AGE], list.first.header
      end

      it "keeps a quoted value with a line break within its row" do
        list = slices(stream(%(name,note\nJack,"line one\nline two"\n)), size: 5)

        assert_equal [[%(Jack,"line one\nline two")]], list
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

        assert_equal [["Jack,21", "Jill,22"]], list
        assert_nil list.first.header
        assert_equal [{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}],
                     parse(list, schema: schema.merge("header" => false))
      end

      it "gives no header row to the slices of a format whose records supply their own keys" do
        list = slices(stream(%({"name":"Jack"}\n{"age":22}\n)).format(:json), size: 5)

        assert_equal [[%({"name":"Jack"}), %({"age":22})]], list
        assert_nil list.first.header
        assert_equal :json, list.first.format
        assert_equal [{"name" => "Jack"}, {"age" => 22}], parse(list)
      end

      it "reads a fixed width file by the position of each field of its schema" do
        fixed = {"fields" => [{"name" => "name", "width" => 4}, {"name" => "age", "type" => "integer", "width" => 2}]}
        list  = slices(stream("Jack21\nJill22\n").format(:fixed).schema(fixed), size: 5)

        assert_equal [%w[Jack21 Jill22]], list
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

        assert_equal [["", %({"name":"Jack","age":"abc"})]], list
      end

      it "are only those of the first record, since the keys of the others are matched where they are parsed" do
        list = slices(stream(%({"name":"Jack","age":21}\n{"x":1}\n)).format(:json).schema(equal), size: 5)

        assert_equal [[%({"name":"Jack","age":21}), %({"x":1})]], list
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

        assert_equal [["Jack,21"]], list
      end

      it "still yields the rows as they are in the file" do
        assert_equal [["Jack,21"]], slices(stream("name,age\nJack,21\n").schema(schema), size: 1, validate: true)
      end

      it "does not parse the rows by default" do
        assert_equal [["Jack,21", "Jill,abc"]], slices(stream(invalid).schema(schema), size: 2)
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

      it "accepts the column options when they are nil, as with a schema, so that a caller can supply them in every mode" do
        list = slices(stream(csv).schema(schema), size: 2, columns: nil, allowed_columns: nil, required_columns: nil)

        assert_equal [["Jack,21", "Jill,22"], ["Bob,23"]], list
        assert_equal [["Jack,21", "Jill,22"], ["Bob,23"]], slices(stream(csv), size: 2, columns: nil)
      end

      it "accepts skip_unknown, which only applies to allowed_columns, and is deprecated" do
        list = assert_deprecated(/skip_unknown: is deprecated/) { slices(stream(csv), size: 5, skip_unknown: false) }

        assert_equal [["Jack,21", "Jill,22", "Bob,23"]], list
      end

      it "raises for a column option that is not nil, since the header row that it changes is read again elsewhere" do
        error = assert_raises(ArgumentError) { slices(stream(csv), size: 2, columns: %w[name age]) }
        assert_match(/\Acolumns: cannot be supplied to the :slice mode/, error.message)

        error = assert_raises(ArgumentError) do
          slices(stream(csv), size: 2, allowed_columns: %w[name], required_columns: %w[name])
        end
        assert_match(/\Aallowed_columns:, required_columns: cannot be supplied to the :slice mode/, error.message)
      end

      it "raises for cleanse_header, since the header row is read again elsewhere" do
        error = assert_raises(ArgumentError) { slices(stream(csv), size: 2, cleanse_header: false) }
        assert_match(/Unknown option :cleanse_header for the :slice mode/, error.message)
      end

      it "lists only the options that are not deprecated" do
        error = assert_raises(ArgumentError) { slices(stream(csv), size: 2, unknown: 1) }
        assert_match(/Valid options: :delimiter, :buffer_size, :size, :validate\.\z/, error.message)
      end

      it "raises for a setting that describes the file, which is set on the path" do
        error = assert_raises(ArgumentError) { slices(stream(csv), size: 2, schema: schema) }
        assert_match(/set it on the path instead/, error.message)
      end

      it "takes the options of the lines" do
        assert_equal [%w[Jack,21 Jill,22]], slices(stream("name,age|Jack,21|Jill,22"), size: 5, delimiter: "|")
      end

      it "cannot be written" do
        assert_raises(ArgumentError) { stream(+"").writer(:slice) { |_writer| nil } }
      end

      it "are read options, which a writer rejects" do
        error = assert_raises(ArgumentError) { IOStreams.stream(StringIO.new).writer(:line, size: 2) { |_writer| nil } }
        assert_match(/:size only applies when reading/, error.message)
      end
    end
  end

  describe IOStreams::Slice do
    it "is an Array of the rows, with the header row and format" do
      slice = IOStreams::Slice.new(%w[a b], header: %w[name].freeze, format: :csv)

      assert_equal %w[a b], slice
      assert_equal %w[name], slice.header
      assert_equal :csv, slice.format
    end

    it "has no header row nor format by default" do
      assert_nil IOStreams::Slice.new.header
      assert_nil IOStreams::Slice.new.format
    end
  end
end
