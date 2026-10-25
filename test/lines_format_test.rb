# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# The `:lines` format, whose rows are the lines of the file as they are, see `IOStreams::Tabular::Parser::Lines`.
class LinesFormatTest < Minitest::Test
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

  describe "the :lines format" do
    let(:emails) { "jack@example.com\n\"jill\"@example.com\n\n  \nbob,smith@example.com\n" }
    let(:schema) { {"fields" => [{"name" => "email"}]} }

    def lines(data = emails)
      IOStreams.stream(StringIO.new(data)).format(:lines)
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
        message = "The :lines format has no header row, and its rows have no keys, so the keys of its records are " \
                  "named by a schema: set one, whose fields name them"
        missing = IOStreams.path("/missing/emails.txt").format(:lines)

        assert_equal(message, assert_raises(ArgumentError) { missing.each(:hash) { flunk } }.message)
        assert_equal(message, assert_raises(ArgumentError) { missing.writer(:hash) { flunk } }.message)
      end

      it "raises for a schema of more than one field, since each line is one value" do
        two   = {"fields" => [{"name" => "email"}, {"name" => "name"}]}
        error = assert_raises(ArgumentError) { read(lines.schema(two), :array) }

        assert_equal "Each line of the :lines format is one value, so its schema has one field, not 2", error.message
      end

      it "reads the lines of the :line mode as they are, without joining a quoted value" do
        assert_equal ["\"a", "b\""], read(lines("\"a\nb\"\n"), :line)
      end

      it "is not the format of a spreadsheet, whose rows are read as CSV" do
        spreadsheet = IOStreams.path(File.join(__dir__, "files", "spreadsheet.xlsx")).format(:lines)

        assert_raises(ArgumentError) { read(spreadsheet, :array) }
      end

      it "is the format of a file named .lines" do
        assert_equal :lines, IOStreams.path("emails.lines").format
        assert_includes IOStreams.tabular_formats, :lines
      end
    end

    describe "slices" do
      it "reads slices of the lines, without a header row, each with its line and record number" do
        slices = read(lines, :slice, size: 2)

        expected = [
          [:lines, nil, [["jack@example.com", 1, 1], [%("jill"@example.com), 2, 2]]],
          [:lines, nil, [["", 3, 3], ["  ", 4, 4]]],
          [:lines, nil, [["bob,smith@example.com", 5, 5]]]
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

      it "turns into a Hash of plain data and back, whose rows the stream of a slice reads" do
        slice = read(lines("jack@example.com\njill@example.com\n"), :slice, size: 10).first
        hash  = JSON.parse(slice.to_json)
        back  = IOStreams.slice(hash)

        assert_equal({"rows" => ["jack@example.com", "jill@example.com"], "header" => nil, "format" => "lines",
                      "line_number" => 1, "record_number" => 1}, hash)
        assert_equal slice, back
        assert_equal [["jack@example.com"], ["jill@example.com"]], read(IOStreams.stream(back), :array)
        assert_equal [{"email" => "jack@example.com"}, {"email" => "jill@example.com"}],
                     read(IOStreams.stream(back).schema(schema), :hash)
      end

      it "writes its slices to a file of lines, as they are" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "emails.txt").format(:lines)
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

        assert_equal [%i[lines lines lines], [nil, nil, nil]], [store.slices.map(&:format), store.slices.map(&:header)]
        assert_equal [1, 3, 5], store.slices.map(&:line_number)
        assert_equal ["jack@example.com", %("jill"@example.com), "", "  ", "bob,smith@example.com"],
                     store.slices.flat_map(&:rows)
      end

      it "holds the lines of a CSV file as they are, its header row too, once the file is read as lines" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv")
          path.write("name,age\n\"Jack\nSmith\",21\n")
          store = Store.new(10)
          IOStreams.stream(store).copy_from(IOStreams.path(dir, "people.csv").format(:lines), mode: :line)

          assert_equal [[:lines, nil, [["name,age", 1, 1], [%("Jack), 2, 2], [%(Smith",21), 3, 3]]]],
                       described(store.slices)
        end
      end

      it "splits a line written with line breaks into rows, as reading the file back would" do
        store = Store.new(10)
        IOStreams.stream(store).format(:lines).writer(:line) do |io|
          io << "a\nb"
          io << %("c)
          io << "d"
        end

        assert_equal [[:lines, nil, [["a", 1, 1], ["b", 2, 2], [%("c), 3, 3], ["d", 4, 4]]]], described(store.slices)
      end
    end

    describe "writing" do
      it "writes each row of one value as a line, its text, replacing a line break with a space" do
        output = StringIO.new
        IOStreams.stream(output).format(:lines).writer(:array) do |io|
          io << ["jack@example.com"]
          io << [nil]
          io << ["two\nlines"]
          io << [Date.new(2026, 1, 2)]
        end

        assert_equal "jack@example.com\n\ntwo lines\n2026-01-02\n", output.string
      end

      it "writes the value of the field of the schema of each record" do
        output = StringIO.new
        IOStreams.stream(output).format(:lines).schema(schema).writer(:hash) do |io|
          io << {"email" => "jack@example.com"}
          io << {"email" => "jill@example.com"}
        end

        assert_equal "jack@example.com\njill@example.com\n", output.string
      end

      it "copies a column of a CSV file to a file of lines" do
        Dir.mktmpdir do |dir|
          csv = IOStreams.path(dir, "people.csv")
          csv.write("name,email\nJack,jack@example.com\nJill,jill@example.com\n")
          target = IOStreams.path(dir, "emails.txt").format(:lines).schema(schema.merge("fieldsMatch" => "subset"))
          target.copy_from(csv, mode: :hash)

          assert_equal "jack@example.com\njill@example.com\n", target.read
        end
      end

      it "raises for a row of more than one value" do
        error = assert_raises(IOStreams::Errors::TypeMismatch) do
          IOStreams.stream(StringIO.new).format(:lines).writer(:array) { |io| io << %w[a b] }
        end

        assert_equal 'Each row of the :lines format is one value, not 2: ["a", "b"]', error.message
      end
    end
  end
end
