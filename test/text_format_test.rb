# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# The `:text` format, whose rows are the text of each row as it is, see `IOStreams::Tabular::Parser::Text`.
class TextFormatTest < Minitest::Test
  # A store of slices, as an application supplies one, see `IOStreams::Slice::Target`.
  class Store
    include IOStreams::Slice::Target

    attr_reader :slices, :slice_size

    def initialize(slice_size)
      @slice_size = slice_size
      @slices     = []
    end

    def write_slice(slice)
      @slices << slice
    end
  end

  describe "the :text format" do
    let(:emails) { "jack@example.com\n\"jill\"@example.com\n\n  \nbob,smith@example.com\n" }
    let(:schema) { {"fields" => [{"name" => "email"}]} }

    def lines(data = emails)
      IOStreams.stream(StringIO.new(data)).format(:text)
    end

    def read(stream, mode, **)
      list = []
      stream.each(mode, **) { |row| list << row }
      list
    end

    # Returns [Array] the format, header row, and each row with its numbers, of each slice.
    def described(slices)
      slices.collect { |slice| [slice.format, slice.header, slice.each.to_a] }
    end

    describe "reading" do
      it "reads each line as a row of one value, as it is, with no header row, quotes and commas included" do
        expected = [["jack@example.com"], [%("jill"@example.com)], nil, nil, ["bob,smith@example.com"]]

        assert_equal expected, read(lines, :array)
      end

      it "skips the blank lines with skip_blanks: true" do
        expected = [["jack@example.com"], [%("jill"@example.com)], ["bob,smith@example.com"]]

        assert_equal expected, read(lines, :array, skip_blanks: true)
      end

      it "reads the rows after a header row of the name of the field of a schema, by its type" do
        typed = {"fields" => [{"name" => "id", "type" => "integer"}]}

        assert_equal [%w[id], [12], [345]], read(lines("12\n345\n").schema(typed), :array)
        assert_equal [{"id" => 12}, {"id" => 345}], read(lines("12\n345\n").schema(typed), :hash)
      end

      it "keys each record by the field of the schema" do
        records = read(lines.schema(schema), :hash, skip_blanks: true)

        assert_equal [{"email" => "jack@example.com"}, {"email" => %("jill"@example.com)},
                      {"email" => "bob,smith@example.com"}], records
      end

      it "raises for records without a schema, which would name their key, before the file is opened" do
        message = "The :text rows have no header row, and no keys, so the keys of their records are named by a " \
                  "schema: set one, whose fields name them"
        missing = IOStreams.path("/missing/emails.txt").format(:text)

        assert_equal(message, assert_raises(ArgumentError) { missing.each(:hash) { flunk } }.message)
        assert_equal(message, assert_raises(ArgumentError) { missing.writer(:hash) { flunk } }.message)
      end

      it "raises for a schema of more than one field, since each line is one value" do
        two   = {"fields" => [{"name" => "email"}, {"name" => "name"}]}
        error = assert_raises(ArgumentError) { read(lines.schema(two), :array) }

        assert_equal "Each row of the :text format is one value, so its schema has one field, not 2", error.message
      end

      it "reads each line without its line ending, also in a file whose lines end in both ways" do
        assert_equal [["jack@example.com"], ["jill@example.com"], ["bob@example.com"]],
                     read(lines("jack@example.com\njill@example.com\r\nbob@example.com\n"), :array)
      end

      it "keeps a carriage return alone within a line of a file whose lines end at a line feed, as a character of it" do
        assert_equal [["a"], ["b\rc"]], read(lines("a\nb\rc\n"), :array)
        assert_equal [["a"], ["b"], ["c\nd"]], read(lines("a\rb\rc\nd\r"), :array)
      end

      it "reads the lines of the :line mode as they are, without joining a quoted value" do
        assert_equal ["\"a", "b\""], read(lines("\"a\nb\"\n"), :line)
      end

      it "is the format of a file named .text" do
        assert_equal :text, IOStreams.path("emails.text").format
        assert_includes IOStreams.tabular_formats, :text
      end
    end

    describe "a spreadsheet" do
      let(:spreadsheet) { IOStreams.path(File.join(__dir__, "files", "multiline_cell.xlsx")) }
      let(:header) { "first column,second column,third column" }
      let(:row) { %(data 1,data 2,"more\ndata") }

      it "reads each row as its CSV text, the header row too, keeping a cell with a line break in its row" do
        assert_equal [[header], [row]], read(spreadsheet.format(:text), :array)
        assert_equal [header, row], read(spreadsheet.format(:text), :line)
        assert_equal read(spreadsheet, :line), read(spreadsheet.format(:text), :line)
      end

      it "names the text of each row with the field of a schema" do
        records = read(spreadsheet.format(:text).schema({"fields" => [{"name" => "text"}]}), :hash)

        assert_equal [{"text" => header}, {"text" => row}], records
      end

      it "reads slices of its rows without line numbers, since they are not the lines of the file" do
        slices = read(spreadsheet.format(:text), :slice, size: 10)

        assert_equal [[:text, nil, [[header, nil, 1], [row, nil, 2]]]], described(slices)
      end

      it "copies its rows to a store of slices whole, as reading them split them" do
        store = Store.new(10)
        IOStreams.stream(store).copy_from(spreadsheet.format(:text), mode: :line)

        assert_equal [[:text, nil, [[header, nil, 1], [row, nil, 2]]]], described(store.slices)
      end

      it "writes the text of each row as a row of CSV, replacing a line break with a space" do
        Dir.mktmpdir do |dir|
          IOStreams.path(dir, "people.xlsx").format(:text).writer(:array) do |io|
            io << ["name,note"]
            io << [%(Jack,"two\nlines")]
          end

          assert_equal [%w[name note], ["Jack", "two lines"]], read(IOStreams.path(dir, "people.xlsx"), :array)
        end
      end

      it "is not read in a format that parses its rows other than CSV" do
        error = assert_raises(ArgumentError) { read(spreadsheet.format(:json), :array) }

        assert_equal "The format of the rows cannot be :json, since the streams read and write them as :csv. Set the " \
                     "format to :csv, or to nil.", error.message
      end
    end

    describe "rows that are not text" do
      it "raises for the rows of a slice in another format, which are already split" do
        slice = IOStreams::Slice.new(%w[a,b], header: %w[x y], format: :csv)
        error = assert_raises(ArgumentError) { IOStreams.stream(slice).format(:text) }

        assert_equal "The rows of the slice are :csv, so its format cannot be :text", error.message
      end

      it "reads the bytes of a file named .parquet once its format is set, as for any format set" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "emails.parquet")
          path.write("jack@x\n")

          assert_equal [["jack@x"]], read(path.format(:text), :array)
        end
      end
    end

    describe "slices" do
      it "reads slices of the lines, without a header row, each with its line and record number" do
        slices = read(lines, :slice, size: 2)

        expected = [
          [:text, nil, [["jack@example.com", 1, 1], [%("jill"@example.com), 2, 2]]],
          [:text, nil, [["", 3, 3], ["  ", 4, 4]]],
          [:text, nil, [["bob,smith@example.com", 5, 5]]]
        ]

        assert_equal expected, described(slices)
      end

      it "keeps a line that opens a quote a row of its own" do
        slices = read(lines(%(name\n"Jack\nJill"\n)), :slice, size: 10)

        assert_equal [["name", 1, 1], [%("Jack), 2, 2], [%(Jill"), 3, 3]], slices.first.each.to_a
      end

      it "parses each line by the schema with validate: true" do
        typed = {"fields" => [{"name" => "id", "type" => "integer"}]}

        assert_raises(IOStreams::Errors::InvalidValue) do
          read(lines("12\nabc\n").schema(typed), :slice, size: 10, validate: true)
        end
      end

      it "parses each line as a row with validate: true without a schema, since its records have no keys" do
        slices = read(lines("jack@x\njill@x\n"), :slice, size: 10, validate: true)

        assert_equal [["jack@x", 1, 1], ["jill@x", 2, 2]], slices.first.each.to_a

        output = StringIO.new
        IOStreams.stream(output).format(:text).writer(:slice, validate: true) { |io| slices.each { |slice| io << slice } }

        assert_equal "jack@x\njill@x\n", output.string

        store = Store.new(10)
        IOStreams.stream(store).format(:text).writer(:line, validate: true) { |io| io << "jack@x" << "jill@x" }

        assert_equal [["jack@x", 1, 1], ["jill@x", 2, 2]], store.slices.first.each.to_a
      end

      it "turns into a Hash of plain data and back, whose rows the stream of a slice reads" do
        slice = read(lines("jack@example.com\njill@example.com\n"), :slice, size: 10).first
        hash  = JSON.parse(slice.to_json)
        back  = IOStreams.slice(hash)

        assert_equal({"rows" => ["jack@example.com", "jill@example.com"], "header" => nil, "format" => "text",
                      "line_number" => 1, "record_number" => 1}, hash)
        assert_equal slice, back
        assert_equal [["jack@example.com"], ["jill@example.com"]], read(IOStreams.stream(back), :array)
        assert_equal [{"email" => "jack@example.com"}, {"email" => "jill@example.com"}],
                     read(IOStreams.stream(back).schema(schema), :hash)
      end

      it "writes its slices to a file of lines, as they are" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "emails.txt").format(:text)
          path.writer(:slice) do |io|
            read(lines, :slice, size: 2).each { |slice| io << slice }
          end

          assert_equal emails, path.read
        end
      end
    end

    describe "a store of slices" do
      it "holds the lines of a file read as lines, with their line numbers" do
        store = Store.new(2)
        IOStreams.stream(store).copy_from(lines, mode: :line)

        assert_equal [%i[text text text], [nil, nil, nil]], [store.slices.map(&:format), store.slices.map(&:header)]
        assert_equal [1, 3, 5], store.slices.map(&:line_number)
        assert_equal ["jack@example.com", %("jill"@example.com), "", "  ", "bob,smith@example.com"],
                     store.slices.flat_map(&:rows)
      end

      it "holds the lines of a CSV file as they are, its header row too, once the file is read as lines" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv")
          path.write("name,age\n\"Jack\nSmith\",21\n")
          store = Store.new(10)
          IOStreams.stream(store).copy_from(IOStreams.path(dir, "people.csv").format(:text), mode: :line)

          assert_equal [[:text, nil, [["name,age", 1, 1], [%("Jack), 2, 2], [%(Smith",21), 3, 3]]]],
                       described(store.slices)
        end
      end

      it "splits a line written with line breaks into rows, as reading the file back would" do
        store = Store.new(10)
        IOStreams.stream(store).format(:text).writer(:line) do |io|
          io << "a\nb"
          io << %("c)
          io << "d"
        end

        assert_equal [[:text, nil, [["a", 1, 1], ["b", 2, 2], [%("c), 3, 3], ["d", 4, 4]]]], described(store.slices)
      end
    end

    describe "copying its rows" do
      let(:unnamed_message) do
        "The rows written have no header row, and no schema names their columns, as for the rows of the :text " \
          "format, or a slice without a header row, so the first of them would be the header row of the %s format: set " \
          "a schema, whose fields name the columns"
      end

      it "raises, rather than make the first line the header row of a format that takes its columns from it" do
        Dir.mktmpdir do |dir|
          %w[csv json].each do |format|
            target = IOStreams.path(dir, "emails.#{format}")
            target.write("kept")
            error = assert_raises(ArgumentError) { target.copy_from(lines, mode: :array) }

            assert_equal format(unnamed_message, format.to_sym.inspect), error.message
            assert_equal "kept", target.read, "The #{format} file is not opened"
          end
        end
      end

      it "raises for a store of slices in such a format, or a writer of rows supplied to IOStreams.stream" do
        assert_raises(ArgumentError) { IOStreams.stream(Store.new(10)).copy_from(lines, mode: :array) }
        error = assert_raises(ArgumentError) do
          IOStreams.stream(StringIO.new).format(:csv).writer(:array) do |io|
            IOStreams.stream(io).copy_from(lines, mode: :array)
          end
        end

        assert_equal format(unnamed_message, ":csv"), error.message
      end

      it "raises for slices of its lines written to a file in such a format, once the first slice is written" do
        Dir.mktmpdir do |dir|
          target = IOStreams.path(dir, "emails.json")
          target.write("old")
          error = assert_raises(ArgumentError) do
            target.writer(:slice) do |io|
              read(lines, :slice, size: 2).each { |slice| io << slice }
            end
          end

          assert_equal format(unnamed_message, ":json"), error.message
          refute_predicate target, :exist?, "As for any error raised while writing, the file is removed"
        end
      end

      it "copies the rows when a schema names their column, or to a format without a header row" do
        named = IOStreams.stream(StringIO.new).format(:csv).schema(schema)

        assert_equal 2, named.copy_from(lines("jack@x\njill@x\n"), mode: :array)

        output = StringIO.new
        IOStreams.stream(output).format(:text).copy_from(lines("jack@x\njill@x\n"), mode: :array)

        assert_equal "jack@x\njill@x\n", output.string
      end
    end

    describe "writing" do
      it "writes each row of one value as a line, its text, replacing a line break with a space" do
        output = StringIO.new
        IOStreams.stream(output).format(:text).writer(:array) do |io|
          io << ["jack@example.com"]
          io << [nil]
          io << ["two\nlines"]
          io << [Date.new(2026, 1, 2)]
        end

        assert_equal "jack@example.com\n\ntwo lines\n2026-01-02\n", output.string
      end

      it "writes the value of the field of the schema of each record" do
        output = StringIO.new
        IOStreams.stream(output).format(:text).schema(schema).writer(:hash) do |io|
          io << {"email" => "jack@example.com"}
          io << {"email" => "jill@example.com"}
        end

        assert_equal "jack@example.com\njill@example.com\n", output.string
      end

      it "copies a column of a CSV file to a file of lines" do
        Dir.mktmpdir do |dir|
          csv = IOStreams.path(dir, "people.csv")
          csv.write("name,email\nJack,jack@example.com\nJill,jill@example.com\n")
          target = IOStreams.path(dir, "emails.txt").format(:text).schema(schema.merge("fieldsMatch" => "subset"))
          target.copy_from(csv, mode: :hash)

          assert_equal "jack@example.com\njill@example.com\n", target.read
        end
      end

      it "raises for a row of more than one value" do
        error = assert_raises(IOStreams::Errors::TypeMismatch) do
          IOStreams.stream(StringIO.new).format(:text).writer(:array) { |io| io << %w[a b] }
        end

        assert_equal 'Each row of the :text format is one value, not 2: ["a", "b"]', error.message
      end
    end
  end
end
