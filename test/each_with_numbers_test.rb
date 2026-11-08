# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# `IOStreams::Stream#each_with_numbers`, which yields each row or record as #each does, with the line of the file that it
# starts on and its record number.
class EachWithNumbersTest < Minitest::Test
  describe IOStreams::Stream do
    # A blank line before the header row, a quoted value on two lines, a blank row, and a value that is not an integer.
    let(:csv) { "\nname,age\nJack,21\n\"Jill\nSmith\",22\n\nBob,abc\n" }
    let(:schema) { {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]} }

    def stream(data = csv)
      IOStreams.stream(StringIO.new(data)).format(:csv)
    end

    def numbered(source, mode, **)
      list = []
      source.each_with_numbers(mode, **) { |row, line_number, record_number| list << [row, line_number, record_number] }
      list
    end

    describe "#each_with_numbers" do
      describe "the :array mode" do
        it "yields the header row on its line, without a record number, then each row on the line that it starts on" do
          # The blank line before the header row is yielded as nil, as #each yields it, on its line.
          expected = [[nil, 1, nil], [%w[name age], 2, nil], [%w[Jack 21], 3, 1], [%W[Jill\nSmith 22], 4, 2], [nil, 6, 3],
                      [%w[Bob abc], 7, 4]]

          assert_equal expected, numbered(stream, :array)
        end

        it "yields the same rows as #each" do
          rows = []
          stream.each(:array) { |row| rows << row }

          assert_equal rows, numbered(stream, :array).map(&:first)
        end

        it "yields a header row that is not a line of its own without numbers" do
          json  = %({"a":1}\n{"a":2}\n)
          fixed = IOStreams.stream(StringIO.new("0102\n0304\n")).format(:fixed).
                  schema(fields: [{name: "a", width: 2}, {name: "b", width: 2}])

          assert_equal [[%w[a], nil, nil], [[1], 1, 1], [[2], 2, 2]], numbered(stream(json).format(:json), :array)
          assert_equal [[%w[a b], nil, nil], [%w[01 02], 1, 1], [%w[03 04], 2, 2]], numbered(fixed, :array)
        end

        it "keeps the numbers of the file with resume_at:, also for the header row read from the first record skipped" do
          json = %({"a":1}\n{"a":2}\n)

          assert_equal [[nil, 1, nil], [%w[name age], 2, nil], [nil, 6, 3], [%w[Bob abc], 7, 4]],
                       numbered(stream, :array, resume_at: 3)
          assert_equal [[%w[a], nil, nil], [[2], 2, 2]], numbered(stream(json).format(:json), :array, resume_at: 2)
        end

        it "skips a blank row with skip_blanks:, keeping the numbers of the rows after it" do
          expected = [[%w[name age], 2, nil], [%w[Jack 21], 3, 1], [%W[Jill\nSmith 22], 4, 2], [%w[Bob abc], 7, 4]]

          assert_equal expected, numbered(stream, :array, skip_blanks: true)
        end
      end

      describe "the :hash mode" do
        it "yields each record on the line that it starts on, with its record number" do
          expected = [[{"name" => "Jack", "age" => "21"}, 3, 1], [{"name" => "Jill\nSmith", "age" => "22"}, 4, 2],
                      [nil, 6, 3], [{"name" => "Bob", "age" => "abc"}, 7, 4]]

          assert_equal expected, numbered(stream, :hash)
        end

        it "skips a blank record with skip_blanks:, and starts at a record with resume_at:, keeping the numbers" do
          assert_equal [[{"name" => "Bob", "age" => "abc"}, 7, 4]], numbered(stream, :hash, skip_blanks: true, resume_at: 3)
        end

        it "hands a record that is not valid to on_invalid:, with the same numbers, rather than yield it" do
          invalid = []
          rows    = numbered(stream.schema(schema), :hash, on_invalid: ->(row) { invalid << [row.line_number, row.record_number] })

          assert_equal [[7, 4]], invalid
          assert_equal([[3, 1], [4, 2], [6, 3]], rows.map { |row| row.drop(1) })
        end

        it "raises an error of a value that is not valid naming the record and line that it yields them as" do
          error = assert_raises(IOStreams::Errors::InvalidValue) { numbered(stream.schema(schema), :hash) }

          assert_equal [7, 4], [error.line_number, error.record_number]
        end

        it "yields the rows of a slice with the numbers that the slice holds, those of its file" do
          slices = []
          stream.each(:slice, size: 2) { |slice| slices << slice }
          stored = IOStreams.slice(JSON.parse(JSON.generate(slices.last.to_h)))

          assert_equal [[nil, 6, 3], [{"name" => "Bob", "age" => "abc"}, 7, 4]], numbered(IOStreams.stream(stored), :hash)
          assert_equal [[{"name" => "Bob", "age" => "abc"}, 7, 4]], numbered(IOStreams.stream(stored.drop(1)), :hash)
          assert_equal [[%w[name age], nil, nil], [nil, 6, 3], [%w[Bob abc], 7, 4]], numbered(IOStreams.stream(stored), :array)
        end

        it "yields a row that a slice of numbered rows holds without numbers without them, also in the error of such a row" do
          slices = []
          stream.schema(schema).each(:slice, size: 10) { |slice| slices << slice }
          slice = slices.first
          slice << "Ann,24"

          # The blank row, record 3 on line 6, is numbered, and Bob's age is not an integer, so read without a schema.
          assert_equal [[nil, 6, 3], [{"name" => "Bob", "age" => "abc"}, 7, 4], [{"name" => "Ann", "age" => "24"}, nil, nil]],
                       numbered(IOStreams.stream(slice.drop(2)), :hash)
          assert_equal [%w[Ann 24], nil, nil], numbered(IOStreams.stream(slice.drop(2)), :array).last

          bad = IOStreams::Slice.new(["Jack,21"], header: %w[name age], format: :csv, line_number: 3, record_number: 1) << "Ann,abc"
          error = assert_raises(IOStreams::Errors::InvalidValue) { numbered(IOStreams.stream(bad).schema(schema), :hash) }

          assert_equal [nil, nil], [error.line_number, error.record_number]
          error = assert_raises(IOStreams::Errors::InvalidValue) { numbered(IOStreams.stream(bad).schema(schema), :array) }

          assert_equal [nil, nil], [error.line_number, error.record_number]
          invalid = []
          numbered(IOStreams.stream(bad).schema(schema), :hash, on_invalid: ->(row) { invalid << row.record_number })

          assert_equal [nil], invalid
        end

        it "counts the rows of a slice that holds no record numbers, as the lines of a file are counted" do
          slice = IOStreams::Slice.new(["Jack,21", "Jill,abc"], header: %w[name age], format: :csv)

          assert_equal [[{"name" => "Jack", "age" => "21"}, nil, 1], [{"name" => "Jill", "age" => "abc"}, nil, 2]],
                       numbered(IOStreams.stream(slice), :hash)
          error = assert_raises(IOStreams::Errors::InvalidValue) { numbered(IOStreams.stream(slice).schema(schema), :hash) }

          assert_equal [nil, 2], [error.line_number, error.record_number]
        end

        it "yields the rows of a spreadsheet without line numbers, also when read as the text of its rows" do
          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "people.xlsx")
            path.writer(:array) do |io|
              io << %w[name note]
              io << %W[Jack two\nlines]
              io << %w[Jill one]
            end
            text = IOStreams.path(dir, "people.xlsx").format(:text)
            rows = []
            text.each(:array) { |row| rows << row }

            # On lines, Jill would be on line 4, after the two lines of Jack's note.
            assert_equal(rows.zip([1, 2, 3]).map { |row, record_number| [row, nil, record_number] }, numbered(text, :array))
            assert_equal [[{"name" => "Jill", "note" => "one"}, nil, 2]], numbered(path, :hash).drop(1)
          end
        end

        it "yields the records of a Parquet file without line numbers" do
          skip("Parquet is not supported on JRuby") if defined?(JRUBY_VERSION)

          Dir.mktmpdir do |dir|
            typed = {"fields" => [{"name" => "name", "type" => "string"}, {"name" => "age", "type" => "integer"}]}
            path  = IOStreams.path(dir, "people.parquet").schema(typed)
            path.writer(:hash) do |io|
              io << {"name" => "Jack", "age" => 21}
              io << {"name" => "Jill", "age" => 22}
            end

            assert_equal [[{"name" => "Jack", "age" => 21}, nil, 1], [{"name" => "Jill", "age" => 22}, nil, 2]],
                         numbered(IOStreams.path(dir, "people.parquet"), :hash)
          end
        end
      end

      describe "the :record mode" do
        it "yields each record of the contract with its numbers" do
          records = numbered(stream.as(schema), :record, skip_blanks: true, on_invalid: ->(_row) {})

          assert_equal([[{"name" => "Jack", "age" => 21}, 3, 1], [{"name" => "Jill\nSmith", "age" => 22}, 4, 2]],
                       records.map { |record, line_number, record_number| [record.to_h, line_number, record_number] })
        end
      end

      it "raises for any other mode before the file is opened, naming where the numbers of slices and lines are" do
        %i[line slice stream foo].each do |mode|
          opened = false
          path   = IOStreams.stream(StringIO.new(csv))
          error  = assert_raises(ArgumentError) { path.each_with_numbers(mode) { opened = true } }

          assert_match(/Invalid mode: #{mode.inspect}\. #each_with_numbers reads the :array, :hash and :record modes/, error.message)
          assert_includes error.message, "IOStreams::Slice#each"
          refute opened
        end
      end

      it "requires a mode, rather than default to one that #each does not" do
        assert_raises(ArgumentError) { stream.each_with_numbers { nil } }
      end

      it "requires a block, so that the file is closed once read" do
        error = assert_raises(ArgumentError) { stream.each_with_numbers(:hash) }

        assert_match(/#each_with_numbers requires a block/, error.message)
      end

      it "raises for an option that the mode does not take, as #each does" do
        assert_raises(ArgumentError) { stream.each_with_numbers(:hash, size: 2) { nil } }
      end
    end

    describe "#each" do
      it "still spreads each row of the :array mode over the arguments of its block" do
        names = []
        stream.each(:array) { |name, _age| names << name }

        assert_equal [nil, "name", "Jack", "Jill\nSmith", nil, "Bob"], names
      end
    end

    describe "the reader of each mode" do
      it "returns an Enumerator of the rows and their numbers without a block" do
        stream.reader(:array) do |reader|
          assert_equal [[nil, 1, nil], [%w[name age], 2, nil]], reader.each_with_numbers.first(2)
        end
        stream.reader(:hash) do |reader|
          assert_equal [{"name" => "Jack", "age" => "21"}, 3, 1], reader.each_with_numbers.first
        end
      end
    end
  end
end
