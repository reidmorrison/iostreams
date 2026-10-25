# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# `resume_at:` of the `:array`, `:hash` and `:slice` readers, which start at the record of the number supplied.
class ResumeAtTest < Minitest::Test
  describe "resume_at:" do
    # A blank line before the header row, a quoted value on two lines, a value that is not an integer, and a blank row.
    let(:csv) { "\nname,age\nJack,21\n\"Jill\nSmith\",abc\n\nBob,23\nAnn,24\n" }
    let(:schema) { {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]} }

    def stream(data = csv)
      IOStreams.stream(StringIO.new(data))
    end

    def read(source, mode, **)
      list = []
      source.each(mode, **) { |row| list << row }
      list
    end

    # Returns [Array] each row of each slice, with its line and record number.
    def numbered(slices)
      slices.collect { |slice| slice.each.to_a }
    end

    describe "the :slice mode" do
      it "starts the slices with that record, keeping the line and record number of each row in the file" do
        assert_equal [[["", 6, 3], ["Bob,23", 7, 4]], [["Ann,24", 8, 5]]], numbered(read(stream, :slice, size: 2, resume_at: 3))
      end

      it "gives the same slices from there as reading every slice" do
        every = read(stream, :slice, size: 1).drop(2)

        assert_equal every, read(stream, :slice, size: 1, resume_at: 3)
      end

      it "does not parse the rows before it with validate: true" do
        slices = read(stream.schema(schema), :slice, size: 5, resume_at: 3, validate: true)

        assert_equal [["", "Bob,23", "Ann,24"]], slices.map(&:rows)
      end

      it "still matches the header row to the schema, and gives each slice the header row" do
        slices = read(stream.schema(schema), :slice, size: 5, resume_at: 5)

        assert_equal [%w[name age]], slices.map(&:header)
        assert_raises(IOStreams::Errors::InvalidHeader) do
          read(stream.schema({"fields" => [{"name" => "other"}]}), :slice, size: 5, resume_at: 5)
        end
      end

      it "does not check the keys of a first record that it skips, but those of the first that it reads" do
        typed = {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]}
        json  = %({"name":"Jack","extra":1}\n{"name":"Jill","age":22}\n)

        assert_equal [[[%({"name":"Jill","age":22}), 2, 2]]],
                     numbered(read(stream(json).format(:json).schema(typed), :slice, size: 5, resume_at: 2))
        assert_raises(IOStreams::Errors::InvalidHeader) { read(stream(json).format(:json).schema(typed), :slice, size: 5) }
      end

      it "yields no slices after the last record, and returns the number of rows read" do
        list  = []
        count = stream.each(:slice, size: 2, resume_at: 6) { |slice| list << slice }

        assert_empty list
        assert_equal 5, count
      end
    end

    describe "the :hash mode" do
      it "yields the records from it on, without parsing those before it" do
        records = read(stream.schema(schema), :hash, resume_at: 3)

        assert_equal [nil, {"name" => "Bob", "age" => 23}, {"name" => "Ann", "age" => 24}], records
      end

      it "yields one record, or nil for a blank one, for each record, so that counting them from it numbers them" do
        number = 3
        list   = []
        stream.each(:hash, resume_at: number) do |record|
          list << [number, record&.fetch("name")]
          number += 1
        end

        assert_equal [[3, nil], [4, "Bob"], [5, "Ann"]], list
      end

      it "skips the blank records from it on with skip_blanks: true" do
        assert_equal [{"name" => "Bob", "age" => "23"}, {"name" => "Ann", "age" => "24"}],
                     read(stream, :hash, resume_at: 3, skip_blanks: true)
      end
    end

    describe "the :array mode" do
      it "yields the header row, and then the rows of the records from it on" do
        assert_equal [nil, %w[name age], nil, %w[Bob 23], %w[Ann 24]], read(stream, :array, resume_at: 3)
        assert_equal [%w[name age], %w[Bob 23], %w[Ann 24]], read(stream, :array, resume_at: 3, skip_blanks: true)
      end

      it "takes the columns of JSON without a schema from its first record, as when every row is read" do
        json = %({"name":"Jack","age":21}\n{"name":"Jill","note":"x"}\n{"name":"Bob","age":23}\n)

        assert_equal [%w[name age], ["Bob", 23]], read(stream(json).format(:json), :array, resume_at: 3)
      end

      it "does not parse the first record that it skips, whose keys or fields give the header row" do
        typed  = {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]}
        json   = %({"name":"Jack","age":"abc"}\n{"name":"Jill","age":22}\n)

        assert_equal [%w[name age], ["Jill", 22]], read(stream(json).format(:json).schema(typed), :array, resume_at: 2)
      end

      it "yields the names of the fields of a file without a header row first" do
        fixed = {"fields" => [{"name" => "name", "width" => 5}, {"name" => "age", "width" => 3, "type" => "integer"}]}

        assert_equal [%w[name age], ["Jill", 22]], read(stream("Jack 021\nJill 022\n").format(:fixed).schema(fixed), :array, resume_at: 2)
      end
    end

    describe "a slice" do
      # The second slice of a file: its records 501 to 503, on lines 502 to 504.
      let(:slice) do
        IOStreams::Slice.new(%w[Ann,24 Bob,25 Cy,26], header: %w[name age], format: :csv, line_number: 502,
                                                       record_number: 501)
      end

      it "resumes at a record number that the slice holds, as it gives them, in every mode" do
        assert_equal [{"name" => "Bob", "age" => "25"}, {"name" => "Cy", "age" => "26"}],
                     read(IOStreams.stream(slice), :hash, resume_at: 502)
        assert_equal [%w[name age], %w[Cy 26]], read(IOStreams.stream(slice), :array, resume_at: 503)
        assert_equal [[["Bob,25", 503, 502], ["Cy,26", 504, 503]]],
                     numbered(read(IOStreams.stream(slice), :slice, size: 5, resume_at: 502))
      end

      it "reads no rows from the record after its last, where a job that processed every row resumes" do
        assert_empty read(IOStreams.stream(slice), :hash, resume_at: 504)
        assert_equal [%w[name age]], read(IOStreams.stream(slice), :array, resume_at: 504)
      end

      it "raises for a record that it does not hold, such as the position of a row, before reading it" do
        message = "The slice holds records 501 to 503, so it cannot start from record %d: supply one of them, or " \
                  "504, after its last"

        [2, 500, 505].each do |record|
          error = assert_raises(ArgumentError) { read(IOStreams.stream(slice), :hash, resume_at: record) }

          assert_equal format(message, record), error.message
        end
      end

      it "resumes at the next row for a record that it no longer holds" do
        slice.delete_at(1)

        assert_equal [{"name" => "Cy", "age" => "26"}], read(IOStreams.stream(slice), :hash, resume_at: 502)
      end

      it "keeps the schema of the stream" do
        typed = {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]}

        assert_equal [{"name" => "Cy", "age" => 26}], read(IOStreams.stream(slice).schema(typed), :hash, resume_at: 503)
      end

      it "raises for a slice whose rows have no record numbers" do
        unnumbered = IOStreams::Slice.new(%w[Ann,24], header: %w[name age], format: :csv)

        assert_raises(ArgumentError) { read(IOStreams.stream(unnumbered), :hash, resume_at: 1) }
      end
    end

    describe "other sources" do
      it "resumes at a record of a Parquet file" do
        skip("Parquet is not supported on JRuby") if defined?(JRUBY_VERSION)

        Dir.mktmpdir do |dir|
          typed = {"fields" => [{"name" => "name", "type" => "string"}, {"name" => "age", "type" => "integer"}]}
          path  = IOStreams.path(dir, "people.parquet").schema(typed)
          path.writer(:hash) do |io|
            io << {"name" => "Jack", "age" => 21}
            io << {"name" => "Jill", "age" => 22}
            io << {"name" => "Bob", "age" => 23}
          end
          parquet = IOStreams.path(dir, "people.parquet")

          assert_equal [{"name" => "Bob", "age" => 23}], read(parquet, :hash, resume_at: 3)
          assert_equal([[2, 3]], read(parquet, :slice, size: 5, resume_at: 2).map { |slice| [slice.record_number, slice.record_number_at(-1)] })
        end
      end
    end

    describe "its value" do
      it "reads every record with nil, the cursor of a job that has not started, or 1" do
        assert_equal 5, read(stream, :hash, resume_at: nil).size
        assert_equal 5, read(stream, :hash, resume_at: 1).size
        assert_equal [1], read(stream, :slice, size: 5, resume_at: nil).map(&:record_number)
      end

      it "raises for anything but nil or a positive Integer, before the file is opened" do
        missing = IOStreams.path("/missing/people.csv")

        [0, -1, 1.0, "3"].each do |resume_at|
          error = assert_raises(ArgumentError) { read(missing, :hash, resume_at: resume_at) }

          assert_equal "Invalid resume_at #{resume_at.inspect}: supply the number of a record, counting from 1, or nil",
                       error.message
          assert_raises(ArgumentError) { read(missing, :array, resume_at: resume_at) }
          assert_raises(ArgumentError) { read(missing, :slice, size: 2, resume_at: resume_at) }
        end
      end

      it "only applies when reading, so a writer, a copy and the :line mode raise for it" do
        error = assert_raises(ArgumentError) { IOStreams.stream(StringIO.new).writer(:hash, resume_at: 2) { flunk } }

        assert_equal ":resume_at only applies when reading, not when writing", error.message
        error = assert_raises(ArgumentError) { IOStreams.stream(StringIO.new).copy_from(stream, mode: :hash, resume_at: 2) }

        assert_match(/:resume_at only applies when reading/, error.message)
        assert_raises(ArgumentError) { read(stream, :line, resume_at: 2) }
      end
    end
  end
end
