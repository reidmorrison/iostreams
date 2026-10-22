# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SliceTargetStreamTest < Minitest::Test
  # A store of slices, as an application supplies one, see `IOStreams::Slice::Target`.
  class Store
    include IOStreams::Slice::Target

    attr_reader :slices

    def initialize
      @slices = []
    end

    def write(slice)
      @slices << slice
    end
  end

  describe IOStreams::Slice::TargetStream do
    let(:store) { Store.new }
    let(:schema) { {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]} }
    let(:stream) { IOStreams.stream(store) }

    # Returns [Array] the header row, format and rows of each slice in the store.
    def written
      store.slices.collect { |slice| [slice.header, slice.format, slice.to_a] }
    end

    describe "IOStreams.stream" do
      it "returns the stream of a store of slices, which is a stream" do
        assert_instance_of IOStreams::Slice::TargetStream, stream
        assert_kind_of IOStreams::Stream, stream
      end

      it "returns it for IOStreams.new too" do
        assert_instance_of IOStreams::Slice::TargetStream, IOStreams.new(store)
      end

      it "only takes a store that includes IOStreams::Slice::Target" do
        error = assert_raises(ArgumentError) { IOStreams::Slice::TargetStream.new([]) }

        assert_equal "Not a target of slices: Array, include IOStreams::Slice::Target", error.message
      end
    end

    describe IOStreams::Slice::Target do
      it "stores a slice written with <<, and returns the store" do
        slice = IOStreams::Slice.new(["Jack,21"], header: %w[name age], format: :csv)

        assert_same store, store << slice
        assert_equal [slice], store.slices
      end

      it "raises until the class implements #write" do
        target = Class.new { include IOStreams::Slice::Target }.new

        assert_raises(NotImplementedError) { target << IOStreams::Slice.new }
      end
    end

    describe "#writer(:line)" do
      it "writes the lines in slices of the size, each carrying the header row as it was written" do
        stream.writer(:line, size: 2) do |io|
          io << "Name,AGE" << "Jack,21" << "Jill,22"
          io << "Bob,23"
        end

        header = %w[Name AGE]

        assert_equal [[header, :csv, %w[Jack,21 Jill,22]], [header, :csv, %w[Bob,23]]], written
      end

      it "writes slices of 100 rows by default" do
        stream.writer(:line) do |io|
          io << "name"
          101.times { |i| io << i.to_s }
        end

        assert_equal [100, 1], store.slices.collect(&:size)
      end

      it "gives every slice the same frozen header row" do
        stream.writer(:line, size: 1) { |io| io << "name" << "Jack" << "Jill" }

        assert_same store.slices.first.header, store.slices.last.header
        assert_predicate store.slices.first.header, :frozen?
      end

      it "matches the header row to the schema before the first slice" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) do
          stream.schema(schema).writer(:line) { |io| io << "name,height" << "Jack,180" }
        end

        assert_match(/height/, error.message)
        assert_empty store.slices
      end

      it "writes a blank line as a row, as it is in a file" do
        stream.writer(:line) { |io| io << "name" << "Jack" << nil << "" }

        assert_equal [[%w[name], :csv, ["Jack", "", ""]]], written
      end

      it "writes no slice for a header row without rows" do
        stream.writer(:line) { |io| io << "name,age" }

        assert_empty store.slices
      end

      it "writes the rows in the format of the stream" do
        stream.format(:psv).writer(:line) { |io| io << "name|age" << "Jack|21" }

        assert_equal [[%w[name age], :psv, ["Jack|21"]]], written
      end

      it "gives no header row to the slices of a format without one" do
        stream.format(:json).writer(:line) { |io| io << '{"name":"Jack"}' }

        assert_equal [[nil, :json, ['{"name":"Jack"}']]], written
      end

      it "returns the result of the block" do
        assert_equal(:done, stream.writer(:line) { |io| io << "name" << "Jack" and :done })
      end

      it "raises for a line that is not a String" do
        error = assert_raises(ArgumentError) { stream.writer(:line) { |io| io << {"name" => "Jack"} } }

        assert_equal "Write each line as a String, not a Hash, or write rows or records in the :array or :hash mode",
                     error.message
      end
    end

    describe "#writer(:array)" do
      it "renders the rows as lines, the first row being the header row without a schema" do
        stream.writer(:array) do |io|
          io << %w[name age]
          io << ["Jack, Jr", 21]
        end

        assert_equal [[%w[name age], :csv, ['"Jack, Jr",21']]], written
      end

      it "renders the values of the fields of the schema in order, after their names as the header row" do
        stream.schema(schema).writer(:array) { |io| io << ["Jack", 21] }

        assert_equal [[%w[name age], :csv, %w[Jack,21]]], written
      end
    end

    describe "#writer(:hash)" do
      it "renders the records as lines, after the header row of the keys of the first record" do
        stream.writer(:hash) { |io| io << {"name" => "Jack", "age" => 21} }

        assert_equal [[%w[name age], :csv, %w[Jack,21]]], written
      end

      it "renders each record by the schema" do
        stream.schema(schema).writer(:hash) { |io| io << {"age" => 21, "name" => "Jack"} }

        assert_equal [[%w[name age], :csv, %w[Jack,21]]], written
      end

      it "writes JSON records without a header row" do
        stream.format(:json).writer(:hash) { |io| io << {"name" => "Jack"} }

        assert_equal [[nil, :json, ['{"name":"Jack"}']]], written
      end

      it "writes slices that the stream of a slice reads back" do
        stream.schema(schema).writer(:hash, size: 1) do |io|
          io << {"name" => "Jack", "age" => 21}
          io << {"name" => "Jill", "age" => 22}
        end
        records = store.slices.flat_map do |slice|
          list = []
          IOStreams.stream(slice).schema(schema).each(:hash) { |record| list << record }
          list
        end

        assert_equal [{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}], records
      end
    end

    describe "the last slice" do
      it "is written when the block leaves early with break" do
        stream.writer(:line) do |io|
          io << "name" << "Jack"
          break
        end

        assert_equal 1, store.slices.size
      end

      it "is not written when the block raises" do
        assert_raises(RuntimeError) do
          stream.writer(:line, size: 2) do |io|
            io << "name" << "Jack" << "Jill" << "Bob"
            raise "failed"
          end
        end

        assert_equal [%w[Jack Jill]], store.slices.collect(&:to_a)
      end
    end

    describe "validate:" do
      it "parses each row, and raises for a value that is not valid, after the slices before it" do
        assert_raises(IOStreams::Errors::InvalidValue) do
          stream.schema(schema).writer(:line, size: 1, validate: true) do |io|
            io << "name,age" << "Jack,21" << "Jill,abc"
          end
        end

        assert_equal [%w[Jack,21]], store.slices.collect(&:to_a)
      end

      it "does not parse the rows by default" do
        stream.schema(schema).writer(:line) { |io| io << "name,age" << "Jill,abc" }

        assert_equal [%w[Jill,abc]], store.slices.collect(&:to_a)
      end
    end

    describe "#copy_from" do
      it "copies the lines of a file, keeping a quoted value with a line break within its row" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv.gz")
          path.write("name,age\nJack,21\n\"Jill\nSmith\",22\n")

          assert_equal 3, stream.schema(schema).copy_from(path, mode: :line, size: 1)
        end

        assert_equal [%w[Jack,21], ["\"Jill\nSmith\",22"]], store.slices.collect(&:to_a)
      end

      it "copies the records of a file, rendered by the schema of the stream" do
        source = IOStreams.stream(StringIO.new("AGE,Name\n21,Jack\n")).format(:csv)
        stream.schema(schema).copy_from(source, mode: :hash)

        assert_equal [[%w[name age], :csv, %w[Jack,21]]], written
      end

      it "is what copy_to does with a store" do
        IOStreams.stream(StringIO.new("name\nJack\n")).format(:csv).copy_to(store, mode: :line)

        assert_equal [[%w[name], :csv, %w[Jack]]], written
      end

      it "raises without a mode, or with convert: false, before the source is opened" do
        assert_raises(ArgumentError) { stream.copy_from("missing.csv") }
        assert_raises(ArgumentError) { stream.copy_from("missing.csv", mode: :line, convert: false) }
      end

      it "raises for an option that the writer does not take, before the source is opened" do
        error = assert_raises(ArgumentError) { stream.copy_from("missing.csv", mode: :line, delimiter: "|") }

        assert_match(/Unknown option :delimiter/, error.message)
      end
    end

    describe "options" do
      it "lists the options of the mode" do
        error = assert_raises(ArgumentError) { stream.writer(:hash, delimiter: "|") { nil } }

        assert_equal "Unknown option :delimiter for the :hash mode. Valid options: :size, :validate.", error.message
      end

      it "raises for a size that is not a positive Integer, or a validate that is not true or false" do
        assert_raises(ArgumentError) { stream.writer(:line, size: 0) { nil } }
        assert_raises(ArgumentError) { stream.writer(:line, validate: "yes") { nil } }
      end

      it "raises for a setting that describes the file, which is set on the stream" do
        assert_raises(ArgumentError) { stream.writer(:line, schema: schema) { nil } }
      end

      it "requires a block" do
        assert_raises(ArgumentError) { stream.writer(:line) }
      end
    end

    describe "what needs bytes" do
      it "raises for the :stream mode, and #write" do
        assert_raises(ArgumentError) { stream.writer { nil } }
        assert_raises(ArgumentError) { stream.write("data") }
      end

      it "raises for #stream, #option, #encoding and #raw" do
        assert_raises(ArgumentError) { stream.stream(:gz) }
        assert_raises(ArgumentError) { stream.option(:gz, level: 1) }
        assert_raises(ArgumentError) { stream.encoding("ISO-8859-1") }
        assert_raises(ArgumentError) { stream.raw }
      end

      it "raises for a format whose rows are not lines" do
        error = assert_raises(ArgumentError) { stream.format(:parquet).writer(:hash) { nil } }

        assert_equal "The :parquet format has no lines, so its rows cannot be written to a slice target", error.message
      end
    end

    describe "reading" do
      it "raises, since the store is only written" do
        assert_raises(ArgumentError) { stream.each(:line) { nil } }
        assert_raises(ArgumentError) { stream.read }
        assert_raises(ArgumentError) { stream.reader(:slice, size: 1) { nil } }
      end
    end

    it "shows the class of the store and the format, rather than every instance variable" do
      assert_equal "#<IOStreams::Slice::TargetStream target=SliceTargetStreamTest::Store format=:json>",
                   stream.format(:json).inspect
    end
  end
end
