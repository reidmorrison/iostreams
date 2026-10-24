# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"

class SliceStreamTest < Minitest::Test
  describe IOStreams::Slice::Stream do
    let(:schema) { {"fieldsMatch" => "equal", "fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]} }
    let(:people) { [{"name" => "Jack", "age" => 21}, {"name" => "Jill", "age" => 22}] }

    # Returns [Array<IOStreams::Slice>] the slices of the supplied data, read as a file is read, see `#each(:slice)`.
    def slices(data, format: nil, schema: nil, size: 5)
      source = IOStreams.stream(StringIO.new(data))
      source.format(format) if format
      source.schema(schema) if schema
      list = []
      source.each(:slice, size: size) { |slice| list << slice }
      list
    end

    def each(stream, mode = :hash, **)
      list = []
      stream.each(mode, **) { |row| list << row }
      list
    end

    let(:slice) { slices("AGE,Name\n21,Jack\n22,Jill\n").first }

    describe "IOStreams.stream" do
      it "returns the stream of a slice, which is a stream" do
        stream = IOStreams.stream(slice)

        assert_instance_of IOStreams::Slice::Stream, stream
        assert_kind_of IOStreams::Stream, stream
      end

      it "copies the stream of a slice, as it copies any stream" do
        stream = IOStreams.stream(slice).schema(schema)
        copy   = IOStreams.stream(stream)

        assert_instance_of IOStreams::Slice::Stream, copy
        refute_same stream, copy
        assert_equal people, each(copy)
      end

      it "returns it for IOStreams.new too" do
        assert_instance_of IOStreams::Slice::Stream, IOStreams.new(slice)
      end

      it "only takes a slice" do
        assert_raises(ArgumentError) { IOStreams::Slice::Stream.new(%w[a b]) }
      end
    end

    describe "#each" do
      it "reads the records of the rows by the schema, matched to the header row of the slice" do
        assert_equal people, each(IOStreams.stream(slice).schema(schema))
      end

      it "reads the records by the header row of the slice without a schema, as of a file" do
        assert_equal [{"age" => "21", "name" => "Jack"}, {"age" => "22", "name" => "Jill"}], each(IOStreams.stream(slice))
      end

      it "returns the number of rows read, header row included, as for a file" do
        assert_equal 3, IOStreams.stream(slice).each(:array) { |_row| nil }
        assert_equal 3, IOStreams.stream(slice).each(:hash) { |_record| nil }
      end

      it "reads the rows, after the header row, as of a file" do
        rows = each(IOStreams.stream(slice).schema(schema), :array)

        assert_equal [%w[name age], ["Jack", 21], ["Jill", 22]], rows
        assert_instance_of IOStreams::Row::HeaderRow, rows.first
      end

      it "reads every slice of a file, each one on its own" do
        list = slices("AGE,Name\n21,Jack\n22,Jill\n23,Bob\n", size: 2)

        assert_equal 2, list.size
        records = list.flat_map { |part| each(IOStreams.stream(part).schema(schema)) }

        assert_equal [*people, {"name" => "Bob", "age" => 23}], records
      end

      it "reads a slice turned back from its Hash, once stored as JSON" do
        stored = JSON.generate(slice.to_h)

        assert_equal people, each(IOStreams.stream(IOStreams.slice(JSON.parse(stored))).schema(schema))
      end

      it "reads a quoted line break within a row" do
        slice = slices(%(name,note\nJack,"line one\nline two"\n)).first

        assert_equal [{"name" => "Jack", "note" => "line one\nline two"}], each(IOStreams.stream(slice))
      end

      it "reads a blank row as nil, as of a file" do
        slice = slices("name,age\nJack,21\n\nJill,22\n").first

        assert_equal [{"name" => "Jack", "age" => "21"}, nil, {"name" => "Jill", "age" => "22"}],
                     each(IOStreams.stream(slice))
      end

      describe "of rows that are each a record, such as those of a query" do
        let(:records) do
          rows = [["Jack", 21], [nil, nil], ["", nil]]
          IOStreams::Slice.new(rows, header: %w[name age].freeze, format: :array, blank_rows: false)
        end
        let(:expected) { [{"name" => "Jack", "age" => 21}, {"name" => nil, "age" => nil}, {"name" => "", "age" => nil}] }

        it "reads a row whose every value is blank as a record, with or without skip_blanks" do
          assert_equal expected, each(IOStreams.stream(records).schema(schema))
          assert_equal expected, each(IOStreams.stream(records).schema(schema), :hash, skip_blanks: true)
          assert_equal [%w[name age], *records.rows], each(IOStreams.stream(records), :array, skip_blanks: true)
        end

        it "reads it as a record once the slice is stored as JSON and turned back from its Hash" do
          stored = IOStreams.slice(JSON.parse(JSON.generate(records.to_h)))

          assert_equal expected, each(IOStreams.stream(stored).schema(schema), :hash, skip_blanks: true)
        end

        it "copies a row whose every value is blank" do
          output = StringIO.new
          IOStreams.stream(records).schema(schema).copy_to(IOStreams.stream(output).format(:json), mode: :hash)

          assert_equal %({"name":"Jack","age":21}\n{"name":null,"age":null}\n{"name":"","age":null}\n), output.string
        end

        it "gives the slices that its rows are read in again rows that are each a record" do
          list = []
          IOStreams.stream(records).each(:slice, size: 2) { |part| list << part }

          assert_equal [false, false], list.map(&:blank_rows?)
          assert_equal(expected, list.flat_map { |part| each(IOStreams.stream(part).schema(schema)) })
        end
      end

      it "raises InvalidHeader when the header row of the slice does not match the schema" do
        assert_raises(IOStreams::Errors::InvalidHeader) { each(IOStreams.stream(slice).schema(schema.merge("fieldsMatch" => "exact"))) }
      end

      it "raises InvalidValue for a value that is not valid" do
        slice = slices("name,age\nJack,abc\n").first

        assert_raises(IOStreams::Errors::InvalidValue) { each(IOStreams.stream(slice).schema(schema)) }
      end

      it "takes the options of the call, such as skip_blanks" do
        assert_equal people, each(IOStreams.stream(slice).schema(schema), :hash, skip_blanks: true)
      end

      it "reads the rows in slices again" do
        list = []
        IOStreams.stream(slice).each(:slice, size: 1) { |part| list << part }

        assert_equal [["21,Jack"], ["22,Jill"]], list.map(&:rows)
        assert_equal [%w[AGE Name], %w[AGE Name]], list.map(&:header)
        assert_equal %i[csv csv], list.map(&:format)
      end

      it "gives the slices that it reads again the lines of the rows of the slice, and numbers their records from 1" do
        second = slices("Name,AGE\nJack,21\nJill,22\nBob,23\nAnn,24\nSam,25\n", size: 4).last
        list   = []
        IOStreams.stream(second).each(:slice, size: 1) { |part| list << part }

        assert_equal 6, second.line_number
        assert_equal [["Sam,25"]], list.map(&:rows)
        assert_equal [6], list.map(&:line_number)
        assert_equal [1], list.map(&:record_number)
      end

      it "keeps the line of each row, after a row that holds a quoted line break" do
        first = slices(%(\nName,AGE\nJack,21\n"Ji\nll",22\nBob,23\n), size: 5).first
        list  = []
        IOStreams.stream(first).each(:slice, size: 2) { |part| list << part }

        assert_equal [3, 6], list.map(&:line_number)
        assert_equal([[["Jack,21", 3, 1], [%("Ji\nll",22), 4, 2]], [["Bob,23", 6, 3]]], list.map { |part| part.each.to_a })
      end

      it "keeps the lines of the rows of a slice, and none for those without them, numbering every record afresh" do
        changed = IOStreams::Slice.new(header: %w[Name AGE], format: :csv)
        changed.add("Jack,21", line_number: 2, record_number: 1)
        changed.add("Bob,23", line_number: 4, record_number: 3)
        changed << "Ann,24"
        list = []
        IOStreams.stream(changed).each(:slice, size: 2) { |part| list << part }

        assert_equal([[["Jack,21", 2, 1], ["Bob,23", 4, 2]], [["Ann,24", nil, 3]]], list.map { |part| part.each.to_a })
      end

      it "gives the rows of a slice without lines none, and numbers their records" do
        unnumbered = IOStreams::Slice.new(%w[Jack,21 Jill,22 Bob,23], header: %w[Name AGE], format: :csv)
        list       = []
        IOStreams.stream(unnumbered).each(:slice, size: 2) { |part| list << part }

        assert_equal [nil, nil], list.map(&:line_number)
        assert_equal [1, 3], list.map(&:record_number)
      end

      it "copies the records of the slice to a stream" do
        output = StringIO.new
        IOStreams.stream(slice).schema(schema).copy_to(IOStreams.stream(output).format(:json), mode: :hash)

        assert_equal %({"name":"Jack","age":21}\n{"name":"Jill","age":22}\n), output.string
      end
    end

    describe "the format" do
      it "is the format of the slice" do
        assert_equal :csv, IOStreams.stream(slice).format
      end

      it "reads the rows of a slice in its format" do
        psv  = slices("name|age\nJack|21\n", format: :psv).first
        json = slices(%({"name":"Jack","age":21}\n), format: :json).first

        assert_equal [{"name" => "Jack", "age" => 21}], each(IOStreams.stream(psv).schema(schema))
        assert_equal [{"name" => "Jack", "age" => 21}], each(IOStreams.stream(json).schema(schema))
      end

      it "reads a fixed width slice by the position of each field of its schema" do
        fixed = {"fields" => [{"name" => "name", "width" => 4}, {"name" => "age", "type" => "integer", "width" => 2}]}
        slice = slices("Jack21\nJill22\n", format: :fixed, schema: fixed).first

        assert_equal people, each(IOStreams.stream(slice).schema(fixed))
      end

      it "reads the records of a Parquet slice" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        typed = {"fields" => [{"name" => "name", "type" => "string"}, {"name" => "age", "type" => "integer"}]}
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.parquet").schema(typed)
          path.writer(:hash) { |io| people.each { |person| io << person } }
          list = []
          path.each(:slice, size: 5) { |slice| list << slice }

          assert_nil list.first.header
          assert_equal :parquet, list.first.format
          assert_equal people, each(IOStreams.stream(list.first).schema(typed))
        end
      end

      it "can be set to the format of the slice" do
        assert_equal people, each(IOStreams.stream(slice).format("csv").schema(schema))
      end

      it "raises for another format than the format of the slice" do
        error = assert_raises(ArgumentError) { IOStreams.stream(slice).format(:psv) }
        assert_equal "The rows of the slice are :csv, so its format cannot be :psv", error.message
      end

      it "is set for a slice without one, which otherwise holds its rows as they are, rather than read them as CSV" do
        slice = IOStreams::Slice.new(%w[Jack|21], header: %w[name age])

        assert_equal [{"name" => "Jack", "age" => 21}], each(IOStreams.stream(slice).format(:psv).schema(schema))
        assert_equal %w[Jack|21], each(IOStreams.stream(slice))
      end
    end

    describe "the :none format" do
      let(:slice) do
        rows = IOStreams::Slice.new(header: %w[first last], format: :none)
        rows.add([1, 99], line_number: 2, record_number: 1)
        rows.add(nil, line_number: 3, record_number: 2)
        rows.add("two\nlines", line_number: 4, record_number: 3)
      end

      it "reads each row as it is in the :array and :hash modes, after its header row" do
        assert_equal [[1, 99], nil, "two\nlines"], each(IOStreams.stream(slice), :array)
        assert_equal [[1, 99], nil, "two\nlines"], each(IOStreams.stream(slice), :hash)
        assert_equal [[1, 99], "two\nlines"], each(IOStreams.stream(slice), :array, skip_blanks: true)
      end

      it "reads slices of the rows as they are, with the header row and the line of each row" do
        slices = each(IOStreams.stream(slice), :slice, size: 2)

        assert_equal([[[[1, 99], 2, 1], [nil, 3, 2]], [["two\nlines", 4, 3]]], slices.map { |s| s.each.to_a })
        assert_equal [%w[first last], %w[first last]], slices.map(&:header)
        assert_equal %i[none none], slices.map(&:format)
      end

      it "copies the rows as they are to a file, after the header row" do
        ranges = IOStreams::Slice.new([[1, 99], nil, [100, 199]], header: %w[first last], format: :none)
        output = StringIO.new
        IOStreams.stream(output).format(:json).copy_from(IOStreams.stream(ranges), mode: :array)

        assert_equal %({"first":1,"last":99}\n{"first":100,"last":199}\n), output.string
      end

      it "raises for validate: true, or an option that a mode does not take" do
        assert_raises(ArgumentError) { each(IOStreams.stream(slice), :slice, size: 2, validate: true) }
        assert_raises(ArgumentError) { each(IOStreams.stream(slice), :array, size: 2) }
      end
    end

    describe "what a slice does not have" do
      let(:stream) { IOStreams.stream(slice) }

      it "raises for the :stream and :line modes, since a slice holds rows" do
        assert_raises(ArgumentError) { stream.each { |_line| nil } }
        assert_raises(ArgumentError) { stream.each(:line) { |_line| nil } }
        error = assert_raises(ArgumentError) { stream.reader { |_io| nil } }
        assert_match(/\AA slice is read in the :array, :hash or :slice mode, not :stream/, error.message)
        assert_raises(ArgumentError) { stream.read }
      end

      it "raises for writing, since a slice is only read" do
        assert_raises(ArgumentError) { stream.writer(:hash) { |_io| nil } }
        assert_raises(ArgumentError) { stream.write("a") }
        assert_raises(ArgumentError) { stream.copy_from(StringIO.new("a,b\n"), mode: :line) }
      end

      it "raises for streams, options, an encoding and #raw, since a slice has no bytes" do
        assert_raises(ArgumentError) { stream.stream(:gz) }
        assert_raises(ArgumentError) { stream.option(:pgp, passphrase: "secret") }
        assert_raises(ArgumentError) { stream.option_or_stream(:gz) }
        assert_raises(ArgumentError) { stream.option(:parquet, compression: "zstd") }
        assert_raises(ArgumentError) { stream.encoding("BINARY") }
        assert_raises(ArgumentError) { stream.raw }
        assert_raises(ArgumentError) { stream.remove_from_pipeline(:gz) }
        assert_nil stream.encoding
        assert_empty stream.pipeline
      end

      it "raises for the options of lines, since the rows of a slice are already split" do
        error = assert_raises(ArgumentError) { each(stream, :hash, delimiter: "|", buffer_size: 10) }
        assert_equal "delimiter:, buffer_size: cannot be used to read a slice, whose rows are already split", error.message
        assert_raises(ArgumentError) { each(stream, :array, embedded_within: '"') }
      end
    end

    it "shows the number of rows and their format" do
      assert_equal "#<IOStreams::Slice::Stream rows=2 format=:csv>", IOStreams.stream(slice).inspect
    end
  end
end
