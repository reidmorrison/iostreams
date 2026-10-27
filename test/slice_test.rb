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

      it "holds the record number of the first row, when the slice has one" do
        numbered = IOStreams::Slice.new(%w[a b], format: :csv, line_number: 7, record_number: 3)

        assert_equal({"rows" => %w[a b], "header" => nil, "format" => "csv", "line_number" => 7, "record_number" => 3},
                     numbered.to_h)
      end

      it "holds the jumps of the rows that do not follow the row before them" do
        numbered = IOStreams::Slice.new
        numbered.add("a", line_number: 2, record_number: 1)
        numbered.add(%("b\nc"), line_number: 3, record_number: 2)
        numbered.add("d", line_number: 5, record_number: 3)
        numbered.add("e", line_number: 6, record_number: 4)

        assert_equal({"rows" => ["a", %("b\nc"), "d", "e"], "header" => nil, "format" => nil, "line_number" => 2,
                      "record_number" => 1, "jumps" => [[2, 5, 3]]}, numbered.to_h)
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

        assert_equal %w[a], copy.rows
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
          slice.rows.map { |row| tabular.record_parse(row) }
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
        assert_equal 'Unknown key "line" of a slice. Valid keys: "rows", "header", "format", "blank_rows", "typed", ' \
                     '"line_number", "record_number", "jumps"', error.message
      end

      it "turns back the line that the first row starts on, once stored as JSON, or nil for a Hash without one" do
        numbered = IOStreams::Slice.new(%w[a], format: :csv, line_number: 7)

        assert_equal 7, IOStreams.slice(JSON.parse(JSON.generate(numbered.to_h))).line_number
        assert_equal 7, IOStreams.slice(rows: %w[a], line_number: 7).line_number
        assert_nil IOStreams.slice("rows" => %w[a]).line_number
      end

      it "raises for a line number or record number without rows, since they are those of the first row" do
        error = assert_raises(ArgumentError) { IOStreams.slice(rows: [], line_number: 7) }
        assert_equal "A slice without rows has no line_number or record_number, since they are those of its first row: " \
                     "supply them when it is added, with #add(row, line_number:, record_number:)", error.message
        assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "record_number" => 1) }
      end

      it "turns back the lines and record numbers of the slices that a file was read in" do
        stored = slices(%(Name,AGE\nJack,21\n"Ji\nll",22\nBob,23\n)).map { |slice| JSON.generate(slice.to_h) }
        copies = stored.map { |json| IOStreams.slice(JSON.parse(json)) }

        assert_equal([2, 5], copies.map(&:line_number))
        assert_equal([[2, 1], [3, 2]], copies.first.each.map { |_row, line, record| [line, record] })
        assert_equal([[5, 3]], copies.last.each.map { |_row, line, record| [line, record] })
      end

      it "turns back the numbers of every row, once stored as JSON" do
        numbered = IOStreams::Slice.new
        [["a", 2, 1], ["b", 3, 2], ["c", 7, 3], ["d", nil, nil], ["e", 8, 9]].each do |row, line, record|
          numbered.add(row, line_number: line, record_number: record)
        end
        copy = IOStreams.slice(JSON.parse(JSON.generate(numbered.to_h)))

        assert_equal numbered, copy
        assert_equal([2, 3, 7, nil, 8], (0...5).map { |index| copy.line_number_at(index) })
        assert_equal([1, 2, 3, nil, 9], (0...5).map { |index| copy.record_number_at(index) })
      end

      it "turns back a jump that the rows before it already give, without holding it" do
        copy = IOStreams.slice("rows" => %w[a b c], "line_number" => 2, "record_number" => 1, "jumps" => [[1, 3, 2]])

        assert_equal IOStreams::Slice.new(%w[a b c], line_number: 2, record_number: 1), copy
        refute copy.to_h.key?("jumps")
      end

      it "raises for a line_number or record_number that is not a positive Integer" do
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "line_number" => "2") }
        assert_equal 'The line_number of a row of a slice must be a positive Integer, or nil: "2"', error.message
        assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "line_number" => 0) }
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "record_number" => 1.5) }
        assert_equal "The record_number of a row of a slice must be a positive Integer, or nil: 1.5", error.message
      end

      it "raises for jumps that are not those of its rows" do
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => %w[a b], "jumps" => {}) }
        assert_equal "The jumps of a slice must be an Array, not Hash", error.message
        [[[0, 2, 1]], [[2, 5, 3]], [[1, 5]], [1], [[1, 5, 3], [1, 6, 4]]].each do |jumps|
          error = assert_raises(ArgumentError) { IOStreams.slice("rows" => %w[a b], "jumps" => jumps) }
          assert_match(/\AEach jump of a slice must be the \[index, line_number, record_number\] of one of its rows /,
                       error.message)
        end
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => %w[a b], "jumps" => [[1, 0, 2]]) }
        assert_equal "The line_number of a row of a slice must be a positive Integer, or nil: 0", error.message
      end

      it "raises for a blank_rows that is not true or false" do
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "blank_rows" => "false") }
        assert_equal 'The blank_rows of a slice must be true or false: "false"', error.message
      end

      it "raises for a header row that is not an Array of Strings" do
        assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "header" => "Name,AGE") }
        assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "header" => [1, 2]) }
      end

      it "raises for a blank header row, which reading would skip, taking the first row as the header row instead" do
        [[], [nil], ["", " "]].each do |blank|
          error = assert_raises(ArgumentError) { IOStreams.slice("rows" => %w[Jack,21], "header" => blank, "format" => "csv") }
          assert_equal "The header row of a slice must be an Array of its columns that is not blank, or nil for a slice " \
                       "without one: #{blank.inspect}", error.message
        end
      end

      it "raises for a format that is not a tabular format" do
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "format" => "gz") }
        assert_match(/\AUnknown format of a slice: "gz"\. Valid formats: /, error.message)
        assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "format" => 1) }
      end
    end

    describe "#typed?" do
      let(:typed) { IOStreams::Slice.new([{"name" => "Jack", "on" => Date.new(2026, 1, 2)}], format: :hash, typed: true) }

      it "is false unless the slice says that its values are those of the fields of a schema" do
        refute_predicate slice, :typed?
        assert_predicate typed, :typed?
      end

      it "is held by the Hash of the slice only when it is true, which IOStreams.slice turns back" do
        assert typed.to_h["typed"]
        refute slice.to_h.key?("typed")
        assert_predicate IOStreams.slice(typed.to_h), :typed?
        assert_predicate IOStreams.slice(rows: [], format: "hash", typed: true), :typed?
        refute_predicate IOStreams.slice(rows: []), :typed?
        refute_predicate IOStreams.slice(rows: [], typed: false), :typed?
      end

      it "makes slices that differ by it not equal" do
        refute_equal typed, IOStreams::Slice.new(typed.rows, format: :hash)
      end

      it "is kept by #drop" do
        assert_predicate typed.drop(1), :typed?
      end

      it "raises for one that is not true or false" do
        error = assert_raises(ArgumentError) { IOStreams::Slice.new([], typed: "true") }
        assert_equal 'The typed of a slice must be true or false: "true"', error.message
        error = assert_raises(ArgumentError) { IOStreams.slice("rows" => [], "typed" => 1) }
        assert_equal "The typed of a slice must be true or false: 1", error.message
      end

      it "is only true for a format whose rows hold the values themselves, since the rows of any other are text" do
        %i[hash array parquet].each do |format|
          assert_predicate IOStreams::Slice.new([], format: format, typed: true), :typed?, format
        end
        [:csv, :json, :fixed, :text, nil].each do |format|
          error = assert_raises(ArgumentError, format.inspect) { IOStreams::Slice.new(["12,2026-01-02"], format: format, typed: true) }
          assert_equal "A slice of the #{format.inspect} format cannot be typed, since its rows are text: only the rows of a " \
                       "format whose rows hold the values themselves, such as :hash or :array, can be", error.message
        end
        assert_raises(ArgumentError) { IOStreams.slice("rows" => ["12"], "header" => ["amount"], "format" => "csv", "typed" => true) }
      end
    end

    describe "#same_file?" do
      let(:typed) { IOStreams::Slice.new([[1]], header: %w[amount], format: :array, typed: true) }

      it "is true for a slice whose rows are read as those of this one, whatever its rows and numbers" do
        assert typed.same_file?(IOStreams::Slice.new([[2], [3]], header: %w[amount], format: :array, typed: true,
                                                                 record_number: 5))
      end

      it "is false for a slice of another header row, format, or whose blank rows or values are read otherwise" do
        refute typed.same_file?(IOStreams::Slice.new([[1]], header: %w[total], format: :array, typed: true))
        refute typed.same_file?(IOStreams::Slice.new([[1]], header: %w[amount], format: :hash, typed: true))
        refute typed.same_file?(IOStreams::Slice.new([[1]], header: %w[amount], format: :array))
        refute typed.same_file?(IOStreams::Slice.new([[1]], header: %w[amount], format: :array, typed: true,
                                                            blank_rows: false))
        refute typed.same_file?([[1]])
      end
    end

    describe "#with_rows" do
      let(:records) do
        IOStreams::Slice.new([[nil, nil]], header: %w[name age], format: :array, blank_rows: false, typed: true,
                                           line_number: 2, record_number: 1)
      end

      it "returns a new slice of the supplied rows, described as this slice is, without numbers" do
        copy = records.with_rows([%w[Jill 22], %w[Bob 30]])

        assert_equal [[%w[Jill 22], nil, nil], [%w[Bob 30], nil, nil]], copy.each.to_a
        assert_equal %w[name age], copy.header
        assert_equal :array, copy.format
        refute_predicate copy, :blank_rows?
        assert_predicate copy, :typed?
        assert_equal [[nil, nil]], records.rows
      end

      it "returns a slice without rows without any" do
        assert_empty records.with_rows
      end

      it "raises when the rows are not an Array" do
        assert_raises(ArgumentError) { records.with_rows("Jill,22") }
      end
    end

    describe "#header?" do
      it "is true for a slice that carries the header row of its file" do
        assert_predicate slice, :header?
      end

      it "is false for a slice without one" do
        refute_predicate IOStreams::Slice.new(%w[Jack,21], format: :csv), :header?
      end

      it "raises for a header row that is not an Array, or is blank, rather than take the first row as the header row" do
        [false, "Name,AGE", [], [nil, ""]].each do |header|
          error = assert_raises(ArgumentError) { IOStreams::Slice.new(%w[Jack,21], header: header, format: :csv) }
          assert_match(/\AThe header row of a slice must be an Array of its columns that is not blank/, error.message)
        end
      end
    end

    describe "#each" do
      let(:numbered) do
        IOStreams::Slice.new.add("a", line_number: 2, record_number: 1).
          add(%("b\nc"), line_number: 3, record_number: 2).
          add("d", line_number: 5, record_number: 3)
      end

      it "yields each row with its line number and record number" do
        yielded = []
        result  = numbered.each { |row, line_number, record_number| yielded << [row, line_number, record_number] }

        assert_equal [["a", 2, 1], [%("b\nc"), 3, 2], ["d", 5, 3]], yielded
        assert_same numbered, result
      end

      it "yields the row alone to a block that takes one value" do
        count = 0
        numbered.each do |row|
          assert_kind_of String, row
          count += 1
        end

        assert_equal 3, count
      end

      it "yields the row alone to a lambda or a method that takes one argument" do
        rows = []
        numbered.each(&rows.method(:<<))
        numbered.each(&->(row) { rows << row.upcase })

        assert_equal ["a", %("b\nc"), "d", "A", %("B\nC"), "D"], rows
      end

      it "yields each row with its numbers to a lambda that takes them" do
        yielded = []
        numbered.each(&->(row, line_number, record_number) { yielded << [row, line_number, record_number] })

        assert_equal [["a", 2, 1], [%("b\nc"), 3, 2], ["d", 5, 3]], yielded
      end

      it "numbers each row after the first as the next line and record, from those that the slice is built with" do
        built = IOStreams::Slice.new(%w[a b], line_number: 4, record_number: 3)

        assert_equal [["a", 4, 3], ["b", 5, 4]], built.each.to_a
      end

      it "yields no numbers for rows without them" do
        assert_equal [["a", nil, nil], ["b", nil, nil]], IOStreams::Slice.new(%w[a b]).each.to_a
      end

      it "returns an Enumerator without a block" do
        enumerator = numbered.each

        assert_instance_of Enumerator, enumerator
        assert_equal 3, enumerator.size
        assert_equal ["d", 5, 3], enumerator.to_a.last
      end
    end

    describe "#line_number_at and #record_number_at" do
      let(:numbered) do
        IOStreams::Slice.new.add("a", line_number: 2, record_number: 1).
          add("b", line_number: 6, record_number: 2).
          add("c", line_number: 7, record_number: 3).
          add("d")
      end

      it "return the numbers of the row at the index" do
        assert_equal([2, 6, 7, nil], (0...4).map { |index| numbered.line_number_at(index) })
        assert_equal([1, 2, 3, nil], (0...4).map { |index| numbered.record_number_at(index) })
      end

      it "count from the end for a negative index" do
        assert_equal 7, numbered.line_number_at(-2)
        assert_equal 1, numbered.record_number_at(-4)
      end

      it "raise IndexError when the slice has no row at the index" do
        error = assert_raises(IndexError) { numbered.line_number_at(4) }
        assert_equal "index 4 outside of the rows of the slice: -4...4", error.message
        assert_raises(IndexError) { numbered.record_number_at(-5) }
        assert_raises(IndexError) { IOStreams::Slice.new.line_number_at(0) }
      end

      it "raise ArgumentError for an index that is not an Integer" do
        error = assert_raises(ArgumentError) { numbered.line_number_at("1") }
        assert_equal "The index of a row of a slice must be an Integer, not String", error.message
      end
    end

    describe "#add" do
      it "adds the row after the rows of the slice, with its numbers" do
        built = IOStreams::Slice.new(%w[a], line_number: 2, record_number: 1)

        assert_same built, built.add("b", line_number: 3, record_number: 2)
        assert_equal %w[a b], built.rows
        assert_nil built.to_h["jumps"]
      end

      it "gives the first row added to an empty slice the numbers that it is added with" do
        built = IOStreams::Slice.new(header: %w[name], format: :csv)
        built.add("a", line_number: 4, record_number: 2)

        assert_equal 4, built.line_number
        assert_equal 2, built.record_number
      end

      it "raises for numbers of an empty slice, rather than lose them when its first row is added" do
        assert_raises(ArgumentError) { IOStreams::Slice.new(header: %w[name], format: :csv, line_number: 2) }
        assert_raises(ArgumentError) { IOStreams::Slice.new([], record_number: 1) }
      end

      it "adds a row without numbers, such as a row that is not from a file" do
        built = IOStreams::Slice.new(%w[a b], line_number: 2, record_number: 1)
        built.add("c")
        built << "d"

        assert_equal [["a", 2, 1], ["b", 3, 2], ["c", nil, nil], ["d", nil, nil]], built.each.to_a
      end

      it "raises for numbers that are not positive Integers, before it adds the row" do
        built = IOStreams::Slice.new(%w[a], line_number: 2, record_number: 1)

        error = assert_raises(ArgumentError) { built.add("b", line_number: 0) }
        assert_equal "The line_number of a row of a slice must be a positive Integer, or nil: 0", error.message
        assert_raises(ArgumentError) { built.add("b", line_number: 3, record_number: "2") }
        assert_raises(ArgumentError) { IOStreams::Slice.new.add("a", record_number: -1) }
        assert_equal %w[a], built.rows

        empty = IOStreams::Slice.new
        assert_raises(ArgumentError) { empty.add("a", line_number: 4, record_number: "1") }
        assert_nil empty.line_number
        assert_empty empty
      end

      it "raises for a Float or Rational number of the row after the last, rather than take it as the next number" do
        built = IOStreams::Slice.new(%w[a], line_number: 2, record_number: 1)

        error = assert_raises(ArgumentError) { built.add("b", line_number: 3.0, record_number: 2) }
        assert_equal "The line_number of a row of a slice must be a positive Integer, or nil: 3.0", error.message
        error = assert_raises(ArgumentError) { built.add("b", line_number: 3, record_number: Rational(2)) }
        assert_equal "The record_number of a row of a slice must be a positive Integer, or nil: (2/1)", error.message
        assert_equal [["a", 2, 1]], built.each.to_a
        assert_equal [["a", 2, 1], ["b", 3, 2]], built.add("b", line_number: 3, record_number: 2).each.to_a
      end

      it "raises once the slice is frozen" do
        frozen = IOStreams::Slice.new(%w[a], line_number: 2).freeze

        assert_raises(FrozenError) { frozen.add("b", line_number: 3) }
        assert_raises(FrozenError) { frozen.add("b", line_number: 9) }
        assert_raises(FrozenError) { frozen << "b" }
        assert_equal %w[a], frozen.rows
      end

      it "raises for a frozen clone, which it leaves as it was, rather than hold a jump for a row that it did not add" do
        frozen = IOStreams::Slice.new(%w[a b], line_number: 2, record_number: 1).add("c", line_number: 9, record_number: 3)
        copy   = frozen.freeze.clone

        assert_predicate copy, :frozen?
        assert_raises(FrozenError) { copy.add("d", line_number: 50, record_number: 4) }
        assert_equal frozen.to_h, copy.to_h
        assert_equal copy, IOStreams.slice(copy.to_h)
      end
    end

    describe "the rows" do
      it "are an Array of their own, so that changing it does not change the slice" do
        rows = slice.rows
        rows << "Bob,23"

        assert_equal 2, slice.size
      end

      it "are a copy of the Array that the slice is built with" do
        rows  = %w[a b]
        built = IOStreams::Slice.new(rows)
        rows << "c"

        assert_equal %w[a b], built.rows
      end

      it "are read by their index, counting from the end for a negative index, as an Array does" do
        assert_equal "Jack,21", slice[0]
        assert_equal %("Ji\nll",22), slice[-1]
        assert_nil slice[2]
        assert_raises(ArgumentError) { slice[0..1] }
      end

      it "have a size" do
        assert_equal 2, slice.size
        refute_empty slice
        assert_empty IOStreams::Slice.new
      end

      it "must be an Array" do
        error = assert_raises(ArgumentError) { IOStreams::Slice.new("Jack,21") }
        assert_equal "The rows of a slice must be an Array, not String", error.message
      end
    end

    describe "changing the rows" do
      # Rows on lines 2, 3 and 4, 5, and 6, so that the third row is a jump, as after a quoted value with a line break.
      let(:numbered) do
        built = IOStreams::Slice.new(header: %w[name].freeze, format: :csv)
        built.add("a", line_number: 2, record_number: 1)
        built.add(%("b\nc"), line_number: 3, record_number: 2)
        built.add("d", line_number: 5, record_number: 3)
        built.add("e", line_number: 6, record_number: 4)
      end

      describe "#[]=" do
        it "replaces the row at the index, which keeps its numbers" do
          numbered[1] = "B"
          numbered[-1] = "E"

          assert_equal [["a", 2, 1], ["B", 3, 2], ["d", 5, 3], ["E", 6, 4]], numbered.each.to_a
        end

        it "raises IndexError when the slice has no row at the index, rather than add one" do
          error = assert_raises(IndexError) { numbered[4] = "f" }
          assert_equal "index 4 outside of the rows of the slice: -4...4", error.message
          assert_raises(IndexError) { numbered[-5] = "f" }
          assert_equal 4, numbered.size
        end

        it "raises for an index that is not an Integer, and once the slice is frozen" do
          assert_raises(ArgumentError) { numbered[0..1] = "f" }
          assert_raises(FrozenError) { numbered.freeze[0] = "f" }
        end
      end

      describe "#delete_at" do
        it "removes the row at the index, and the rows after it keep their numbers" do
          assert_equal %("b\nc"), numbered.delete_at(1)
          assert_equal [["a", 2, 1], ["d", 5, 3], ["e", 6, 4]], numbered.each.to_a
          assert_equal [[1, 5, 3]], numbered.to_h["jumps"]
        end

        it "gives the numbers of the first row to the row after it, when it removes the first row" do
          numbered.delete_at(0)

          assert_equal 3, numbered.line_number
          assert_equal 2, numbered.record_number
          assert_equal [[%("b\nc"), 3, 2], ["d", 5, 3], ["e", 6, 4]], numbered.each.to_a
        end

        it "removes the jump of the row that it removes" do
          numbered.delete_at(-2)

          assert_equal [["a", 2, 1], [%("b\nc"), 3, 2], ["e", 6, 4]], numbered.each.to_a
          assert_equal [[2, 6, 4]], numbered.to_h["jumps"]
        end

        it "numbers a row added after the last one is removed from the row before it" do
          numbered.delete_at(-1)
          numbered.add("f", line_number: 6, record_number: 4)

          assert_nil(numbered.to_h["jumps"]&.find { |jump| jump.first == 3 })
          assert_equal ["f", 6, 4], numbered.each.to_a.last
        end

        it "returns nil when the slice has no row at the index, as an Array does" do
          assert_nil numbered.delete_at(4)
          assert_nil numbered.delete_at(-5)
          assert_equal 4, numbered.size
        end

        it "raises for an index that is not an Integer, and once the slice is frozen" do
          assert_raises(ArgumentError) { numbered.delete_at("0") }
          assert_raises(FrozenError) { numbered.freeze.delete_at(0) }
          assert_equal 4, numbered.size
        end
      end

      describe "#delete_if" do
        it "removes each row for which the block returns true, yielding it with its numbers" do
          yielded = []
          result  = numbered.delete_if do |row, line_number, record_number|
            yielded << [row, line_number, record_number]
            record_number.even?
          end

          assert_same numbered, result
          assert_equal [["a", 2, 1], [%("b\nc"), 3, 2], ["d", 5, 3], ["e", 6, 4]], yielded
          assert_equal [["a", 2, 1], ["d", 5, 3]], numbered.each.to_a
        end

        it "leaves the slice as it was when the block raises" do
          assert_raises(RuntimeError) do
            numbered.delete_if { |row, *| row == "d" ? raise("failed") : true }
          end
          assert_equal 4, numbered.size
        end

        it "returns an Enumerator without a block" do
          assert_equal 4, numbered.delete_if.size
          assert_equal [["d", 5, 3], ["e", 6, 4]], numbered.delete_if.with_index { |_numbers, index| index < 2 }.each.to_a
        end

        it "yields the three values to a lambda" do
          numbered.delete_if(&->(_row, line_number, _record_number) { line_number > 4 })

          assert_equal [["a", 2, 1], [%("b\nc"), 3, 2]], numbered.each.to_a
        end

        it "yields the row alone to a lambda or a method that takes one argument" do
          numbered.delete_if(&->(row) { row == "a" })
          numbered.delete_if(&%w[e].method(:include?))

          assert_equal [[%("b\nc"), 3, 2], ["d", 5, 3]], numbered.each.to_a
        end

        it "raises once the slice is frozen" do
          assert_raises(FrozenError) { numbered.freeze.delete_if { true } }
        end
      end

      describe "#drop" do
        it "returns a new slice of the rows after the first ones, which keep their numbers" do
          rest = numbered.drop(2)

          assert_instance_of IOStreams::Slice, rest
          assert_equal [["d", 5, 3], ["e", 6, 4]], rest.each.to_a
          assert_equal %w[name], rest.header
          assert_equal :csv, rest.format
          assert_equal 4, numbered.size
        end

        it "keeps whether the blank rows are records" do
          records = IOStreams::Slice.new([[nil], %w[a]], format: :array, blank_rows: false, record_number: 1)

          refute_predicate records.drop(1), :blank_rows?
          assert_equal [[%w[a], nil, 2]], records.drop(1).each.to_a
        end

        it "returns every row for 0, and none for more than the slice has" do
          assert_equal numbered, numbered.drop(0)
          assert_empty numbered.drop(5)
        end

        it "leaves a frozen slice as it is, and returns a slice that can be changed" do
          rest = numbered.freeze.drop(3)
          rest << "f"

          assert_equal [["e", 6, 4], ["f", nil, nil]], rest.each.to_a
        end

        it "raises for a count that is not an Integer of 0 or more" do
          error = assert_raises(ArgumentError) { numbered.drop(-1) }
          assert_equal "The number of rows to drop from a slice must be an Integer of 0 or more: -1", error.message
          assert_raises(ArgumentError) { numbered.drop("1") }
        end
      end

      describe "#from_record" do
        it "returns a new slice of the rows from the record on, which keep their numbers" do
          rest = numbered.from_record(3)

          assert_instance_of IOStreams::Slice, rest
          assert_equal [["d", 5, 3], ["e", 6, 4]], rest.each.to_a
          assert_equal %w[name], rest.header
          assert_equal :csv, rest.format
          assert_equal 4, numbered.size
        end

        it "returns every row from its first record, and none from the record after its last" do
          assert_equal numbered, numbered.from_record(1)
          assert_empty numbered.from_record(5)
        end

        it "starts with the row after a record that it no longer holds" do
          numbered.delete_at(1)

          assert_equal [["d", 5, 3], ["e", 6, 4]], numbered.from_record(2).each.to_a
        end

        it "leaves a frozen slice as it is" do
          assert_equal [["e", 6, 4]], numbered.freeze.from_record(4).each.to_a
        end

        it "raises for a record that it does not hold, or one that is not an Integer" do
          error = assert_raises(ArgumentError) { numbered.from_record(6) }
          assert_equal "The slice holds records 1 to 4, so it cannot start from record 6: supply one of them, or 5, " \
                       "after its last", error.message
          assert_raises(ArgumentError) { numbered.from_record(0) }
          assert_raises(ArgumentError) { numbered.from_record("3") }
        end

        it "returns a slice without rows for a slice without rows, which has none to skip" do
          empty = IOStreams::Slice.new(header: %w[name], format: :csv)
          rest  = empty.from_record(7)

          assert_empty rest
          assert_equal %w[name], rest.header
          refute_same empty, rest
        end

        it "raises for a record before its first or after the record after its last, also once those rows are removed" do
          numbered.delete_at(0)
          numbered.delete_at(-1)

          assert_equal [["d", 5, 3]], numbered.from_record(3).each.to_a
          assert_empty numbered.from_record(4)
          assert_raises(ArgumentError) { numbered.from_record(1) }
          assert_raises(ArgumentError) { numbered.from_record(5) }
        end

        it "raises for a slice with a row without a record number" do
          numbered << "f"
          error = assert_raises(ArgumentError) { numbered.from_record(2) }
          assert_equal "A row of the slice has no record number, so it cannot start from record 2", error.message
        end
      end

      it "keeps the numbers of every row through any changes, and once stored as JSON" do
        random = Random.new(42)
        200.times do
          slice    = IOStreams::Slice.new(header: %w[name].freeze, format: :csv)
          expected = []
          line     = random.rand(1..3)
          random.rand(0..8).times do |index|
            slice.add("r#{index}", line_number: line, record_number: index + 1)
            expected << ["r#{index}", line, index + 1]
            line += random.rand(4).zero? ? random.rand(2..4) : 1
          end

          15.times do |step|
            case random.rand(6)
            when 0
              line_number   = random.rand(3).zero? ? nil : random.rand(1..40)
              record_number = random.rand(3).zero? ? nil : random.rand(1..40)
              slice.add("n#{step}", line_number: line_number, record_number: record_number)
              expected << ["n#{step}", line_number, record_number]
            when 1
              slice << "p#{step}"
              expected << ["p#{step}", nil, nil]
            when 2
              next if expected.empty?

              index        = random.rand(-expected.size...expected.size)
              slice[index] = "u#{step}"
              expected[index] = ["u#{step}", *expected[index][1..]]
            when 3
              index = random.rand((-expected.size - 1)..expected.size)

              assert_equal [expected.delete_at(index)&.first], [slice.delete_at(index)]
            when 4
              keep = random.rand(2..4)
              slice.delete_if { |_row, _line_number, record_number| record_number.to_i % keep == 1 }
              expected.delete_if { |_row, _line_number, record_number| record_number.to_i % keep == 1 }
            else
              count    = random.rand(0..3)
              slice    = slice.drop(count)
              expected = expected.drop(count)
            end

            assert_equal expected, slice.each.to_a
            assert_equal(expected.map { |numbers| numbers[1] }, (0...slice.size).map { |index| slice.line_number_at(index) })
            assert_equal(expected.map { |numbers| numbers[2] }, (0...slice.size).map { |index| slice.record_number_at(index) })
            assert_equal slice, IOStreams.slice(JSON.parse(JSON.generate(slice.to_h)))
          end
        end
      end
    end

    describe "#==" do
      it "is true for slices of the same rows, numbers, header row and format" do
        assert_equal slice, IOStreams::Slice.new(["Jack,21", %("Ji\nll",22)], header: %w[Name AGE], format: :csv)
        assert_equal slice.hash, IOStreams::Slice.new(slice.rows, header: %w[Name AGE], format: :csv).hash
      end

      it "is false for other rows, numbers, header row or format, or for an Array of the rows" do
        refute_equal slice, IOStreams::Slice.new(["Jack,21"], header: %w[Name AGE], format: :csv)
        refute_equal slice, IOStreams::Slice.new(slice.rows, header: %w[Name AGE], format: :csv, line_number: 2)
        refute_equal slice, IOStreams::Slice.new(slice.rows, header: %w[Name], format: :csv)
        refute_equal slice, IOStreams::Slice.new(slice.rows, header: %w[Name AGE], format: :psv)
        refute_equal slice, slice.rows
      end

      it "is eql?, as a Hash key, only for rows that are eql?, as an Array is, which have the same hash" do
        integers = IOStreams::Slice.new([[1, "a"]], line_number: 2, record_number: 1)
        floats   = IOStreams::Slice.new([[1.0, "a"]], line_number: 2, record_number: 1)
        same     = IOStreams::Slice.new([[1, "a"]], line_number: 2, record_number: 1)

        assert_equal integers, floats
        refute integers.eql?(floats)
        assert integers.eql?(same)
        assert_equal integers.hash, same.hash
        assert_nil({integers => true}[floats])
        assert({integers => true}[same])
        assert_equal [integers, floats], [integers, floats, same].uniq
      end
    end

    describe "a copy" do
      it "holds rows and numbers of its own" do
        built = IOStreams::Slice.new(%w[a], header: %w[name].freeze, format: :csv, line_number: 2, record_number: 1)
        copy  = built.dup
        copy.add("b", line_number: 9, record_number: 2)

        assert_equal %w[a], built.rows
        assert_nil built.to_h["jumps"]
        assert_equal [["a", 2, 1], ["b", 9, 2]], copy.each.to_a
        assert_equal %w[name], copy.header
        assert_equal :csv, copy.format
      end

      it "of a frozen slice can be changed" do
        copy = slice.freeze.dup
        copy << "Bob,23"

        assert_equal 3, copy.size
        assert_equal 2, slice.size
      end
    end

    describe "JSON" do
      it "is the Hash of the slice, which IOStreams.slice turns back into it" do
        numbered = IOStreams::Slice.new(%w[a b], header: %w[name], format: :csv, line_number: 2, record_number: 1)

        assert_equal numbered.to_h, numbered.as_json
        assert_equal numbered.to_h, numbered.as_json({})
        assert_equal numbered, IOStreams.slice(JSON.parse(numbered.to_json))
        assert_equal numbered, IOStreams.slice(JSON.parse(JSON.generate(numbered)))
      end

      it "raises for the options of as_json without ActiveSupport, which is what applies them, rather than ignore them" do
        options = {only: "rows"}
        error   = assert_raises(ArgumentError) { slice.as_json(options) }
        # Ruby 3.4 inspects the options as {only: "rows"}, and Ruby 3.3 as {:only=>"rows"}.
        assert_equal "The options of Slice#as_json are applied by ActiveSupport, which is not loaded: #{options.inspect}",
                     error.message
      end
    end

    it "shows its format, the numbers of its first row and its rows" do
      numbered = IOStreams::Slice.new(%w[a], format: :csv, line_number: 2, record_number: 1)

      assert_equal '#<IOStreams::Slice format=:csv line_number=2 record_number=1 rows=["a"]>', numbered.inspect
    end
  end
end
