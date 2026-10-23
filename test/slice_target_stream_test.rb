# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SliceTargetStreamTest < Minitest::Test
  # A store of slices, as an application supplies one, see `IOStreams::Slice::Target`.
  class Store
    include IOStreams::Slice::Target

    attr_reader :slices, :events

    def initialize(slice_size: nil)
      @slices     = []
      @events     = []
      @slice_size = slice_size
    end

    def slice_size
      @slice_size || super
    end

    def write_header(header)
      @events << [:header, header]
    end

    def write_slice(slice)
      @slices << slice
      @events << [:slice, slice.to_a]
    end
  end

  describe IOStreams::Slice::TargetStream do
    let(:store) { Store.new }
    let(:schema) { {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]} }
    let(:stream) { IOStreams.stream(store) }

    # Returns [Array] the header row, format and rows of each slice in the store.
    def written(target = store)
      target.slices.collect { |slice| [slice.header, slice.format, slice.to_a] }
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
      # A class that a store inherits from, whose methods have the names of those of the mixin.
      let(:base) do
        Class.new do
          attr_reader :stored, :header

          def slice_size
            7
          end

          def write_header(header)
            @header = header
          end

          def write_slice(slice)
            (@stored ||= []) << slice.to_a
          end
        end
      end

      it "holds slices of 100 rows unless the class says otherwise" do
        assert_equal 100, Class.new { include IOStreams::Slice::Target }.new.slice_size
      end

      it "does nothing with the header row unless the class says otherwise" do
        assert_nil Class.new { include IOStreams::Slice::Target }.new.write_header(%w[name])
      end

      it "raises until the class implements #write_slice" do
        target = Class.new { include IOStreams::Slice::Target }.new

        error = assert_raises(NotImplementedError) { target.write_slice(IOStreams::Slice.new) }
        assert_match(/must implement #write_slice\(slice\)/, error.message)
      end

      it "calls the methods of a class that the store inherits from, rather than its defaults" do
        target = Class.new(base) { include IOStreams::Slice::Target }.new
        IOStreams.stream(target).writer(:line) { |io| io << "name" << "Jack" }

        assert_equal 7, target.slice_size
        assert_equal %w[name], target.header
        assert_equal [%w[Jack]], target.stored
      end

      it "leaves the #write and #<< of a class that the store inherits from as they are" do
        target = Class.new(Thread::Queue) do
          include IOStreams::Slice::Target

          def write_slice(slice)
            push(slice.to_a)
          end
        end.new
        target << "plain"
        IOStreams.stream(target).writer(:line) { |io| io << "name" << "Jack" }

        assert_equal ["plain", %w[Jack]], [target.pop, target.pop]
      end
    end

    describe "#writer(:line)" do
      it "writes the lines in slices of the slice size of the store, each carrying the header row as it was written" do
        small = Store.new(slice_size: 2)
        IOStreams.stream(small).writer(:line) do |io|
          io << "Name,AGE" << "Jack,21" << "Jill,22"
          io << "Bob,23"
        end

        header = %w[Name AGE]

        assert_equal [[header, :csv, %w[Jack,21 Jill,22]], [header, :csv, %w[Bob,23]]], written(small)
      end

      it "writes slices of 100 rows by default" do
        stream.writer(:line) do |io|
          io << "name"
          101.times { |i| io << i.to_s }
        end

        assert_equal [100, 1], store.slices.collect(&:size)
      end

      it "gives every slice the same frozen header row" do
        small = Store.new(slice_size: 1)
        IOStreams.stream(small).writer(:line) { |io| io << "name" << "Jack" << "Jill" }

        assert_same small.slices.first.header, small.slices.last.header
        assert_predicate small.slices.first.header, :frozen?
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

      it "splits a line that holds line endings into rows, as reading the file back would" do
        stream.writer(:line) { |io| io << "a,b\n1,2" << "3,4\n" << "5,6" }

        assert_equal [[%w[a b], :csv, ["1,2", "3,4", "", "5,6"]]], written
      end

      it "keeps a line ending within a quoted value within its row" do
        stream.writer(:line) { |io| io << "name,note" << "Jack,\"line 1\nline 2\"" << "Jill,none" }

        assert_equal [[%w[name note], :csv, ["Jack,\"line 1\nline 2\"", "Jill,none"]]], written
      end

      it "joins a quoted value that continues on the next line written, as in a file" do
        stream.writer(:line) { |io| io << "name,note" << "Jack,\"line 1" << "line 2\"" << "Jill,none" }

        assert_equal [[%w[name note], :csv, ["Jack,\"line 1\nline 2\"", "Jill,none"]]], written
      end

      it "splits a quoted value of a format without quoting at its line ending" do
        stream.format(:json).writer(:line) { |io| io << "{\"name\":\"Jack\"}\n{\"name\":\"Jill\"}" }

        assert_equal [[nil, :json, ['{"name":"Jack"}', '{"name":"Jill"}']]], written
      end

      it "splits at the line ending of the file, which the first line written decides" do
        stream.writer(:line) { |io| io << "a\r\nb" << "c\r\nd" }

        assert_equal [[%w[a], :csv, %w[b c d]]], written
      end

      it "writes the rows of a line kept when the block leaves early with break" do
        stream.writer(:line) do |io|
          io << "name" << "\"Jack" << "Smith\""
          break
        end

        assert_equal [[%w[name], :csv, ["\"Jack\nSmith\""]]], written
      end

      it "raises for a quoted value that is not closed, without writing the last slice" do
        small = Store.new(slice_size: 1)
        assert_raises(IOStreams::Errors::MalformedDataError) do
          IOStreams.stream(small).writer(:line) { |io| io << "name" << "Jack" << "\"Jill" }
        end

        assert_equal [%w[Jack]], small.slices.collect(&:to_a)
      end

      it "raises with the line of the file on which a quoted value that is not closed starts" do
        error = assert_raises(IOStreams::Errors::MalformedDataError) do
          stream.writer(:line) do |io|
            io << "name,note" << "Jack,\"line 1\nline 2\"" << "a\nb" << "Jill,\"open" << "more"
          end
        end

        assert_equal 6, error.line_number
        assert_equal "Unbalanced delimited field, delimiter: \" on line 6.", error.message
      end

      it "raises once the text kept after a quoted value that is not closed exceeds that of a line reader" do
        line    = "x" * 1_000
        limit   = IOStreams::Line::Reader.max_embedded_bytes
        written = 0
        error   = assert_raises(IOStreams::Errors::MalformedDataError) do
          stream.writer(:line) do |io|
            io << "name" << "Jack" << "\"Jill"
            loop do
              io << line
              written += 1
            end
          end
        end

        assert_equal 3, error.line_number
        assert_equal limit / (line.bytesize + 1), written
      end

      describe "text that is not valid UTF-8" do
        let(:lines) { ["", "name,note", "Jack,\"line 1", "line 2\"", "", "Jill,ok", "Bob,\xFFx".dup.force_encoding("UTF-8")] }

        # Returns [IOStreams::Errors::InvalidEncoding] the error that reading the lines from a file raises.
        def read_error(lines)
          Dir.mktmpdir do |dir|
            file_name = File.join(dir, "people.csv")
            File.binwrite(file_name, "#{lines.collect(&:b).join("\n")}\n")
            assert_raises(IOStreams::Errors::InvalidEncoding) { IOStreams.path(file_name).each(:slice, size: 10) { nil } }
          end
        end

        it "raises InvalidEncoding at the byte offset and on the line that reading the file names" do
          error = assert_raises(IOStreams::Errors::InvalidEncoding) do
            stream.writer(:line) { |io| lines.each { |line| io << line } }
          end

          assert_equal 7, error.line_number
          assert_equal 45, error.byte_offset
          assert_equal "\"\\xFF\" is not valid UTF-8 at byte offset 45 on line 7", error.message
          assert_equal read_error(lines).message, error.message
          assert_equal "\xFF".b, error.error_char
          assert_equal Encoding::BINARY, error.source_encoding
          assert_equal Encoding::UTF_8, error.destination_encoding
          assert_kind_of Encoding::UndefinedConversionError, error
        end

        it "raises the same when the lines are written as one" do
          error = assert_raises(IOStreams::Errors::InvalidEncoding) { stream.writer(:line) { |io| io << lines.join("\n") } }

          assert_equal read_error(lines).message, error.message
        end

        it "raises on the line of the character within a quoted value that is still open" do
          open_quote = ["name,note", "Jack,\"line 1", "line \xFF2\"".dup.force_encoding("UTF-8")]
          error      = assert_raises(IOStreams::Errors::InvalidEncoding) do
            stream.writer(:line) { |io| open_quote.each { |line| io << line } }
          end

          assert_equal 3, error.line_number
          assert_equal read_error(open_quote).message, error.message
        end

        it "does not write the slice that the line would be in" do
          small = Store.new(slice_size: 1)
          assert_raises(IOStreams::Errors::InvalidEncoding) do
            IOStreams.stream(small).writer(:line) { |io| io << "name" << "Jack" << "\xFF".b }
          end

          assert_equal [%w[Jack]], small.slices.collect(&:to_a)
        end

        it "reads the bytes of a binary line as UTF-8" do
          stream.writer(:line) { |io| io << "name".b << "Jöe".b }

          assert_equal [[%w[name], :csv, %w[Jöe]]], written
          assert_equal Encoding::UTF_8, store.slices.first.first.encoding
        end

        it "raises for a binary line that is not valid UTF-8" do
          error = assert_raises(IOStreams::Errors::InvalidEncoding) { stream.writer(:line) { |io| io << "name" << "\xFF".b } }

          assert_equal "\"\\xFF\" is not valid UTF-8 at byte offset 5 on line 2", error.message
        end

        it "converts a line in another encoding to UTF-8" do
          stream.writer(:line) do |io|
            io << "name,note" << "J\xF6e,1".dup.force_encoding("ISO-8859-1") << "\"Jill\",2".encode("UTF-16LE")
          end

          assert_equal [[%w[name note], :csv, ["Jöe,1", "\"Jill\",2"]]], written
          assert(store.slices.first.all? { |row| row.encoding == Encoding::UTF_8 })
        end

        it "raises on the line of a character that is not valid in the encoding of a line" do
          error = assert_raises(IOStreams::Errors::InvalidEncoding) do
            stream.writer(:line) { |io| io << "name,note" << "x\ny,\x81".dup.force_encoding("Shift_JIS") }
          end

          assert_equal "\"\\x81\" is not valid Shift_JIS at byte offset 14 on line 3", error.message
        end

        it "replaces each character that is not valid with replace:" do
          stream.encoding(replace: "?").writer(:line) do |io|
            lines.each { |line| io << line }
            io << "\xFF,y".b << "a\xFF\nb,c".dup.force_encoding("UTF-8")
          end

          assert_equal [[%w[name note], :csv, ["Jack,\"line 1\nline 2\"", "", "Jill,ok", "Bob,?x", "?,y", "a?", "b,c"]]],
                       written
        end
      end

      it "raises for a line that is not a String" do
        error = assert_raises(ArgumentError) { stream.writer(:line) { |io| io << {"name" => "Jack"} } }

        assert_equal "Write each line as a String, not a Hash, or write rows or records in the :array or :hash mode",
                     error.message
      end
    end

    describe "#write_header" do
      it "is called once with the header row as it was read, before the first slice" do
        small = Store.new(slice_size: 1)
        IOStreams.stream(small).writer(:line) { |io| io << "Name,AGE" << "Jack,21" << "Jill,22" }

        assert_equal [[:header, %w[Name AGE]], [:slice, %w[Jack,21]], [:slice, %w[Jill,22]]], small.events
        assert_same small.slices.first.header, small.events.first.last
      end

      it "is called as soon as the header row is read, before any row is written" do
        events = nil
        stream.writer(:line) do |io|
          io << "name"
          events = store.events.dup
        end

        assert_equal [[:header, %w[name]]], events
      end

      it "is called for a file with a header row and no rows" do
        stream.writer(:line) { |io| io << "name,age" }

        assert_equal [[:header, %w[name age]]], store.events
      end

      it "is called with the header row of records, and of a copy" do
        stream.schema(schema).writer(:hash) { |io| io << {"name" => "Jack", "age" => 21} }
        IOStreams.stream(StringIO.new("AGE,Name\n21,Jack\n")).format(:csv).copy_to(store, mode: :line)

        assert_equal [[:header, %w[name age]], [:slice, %w[Jack,21]], [:header, %w[AGE Name]], [:slice, %w[21,Jack]]],
                     store.events
      end

      it "is not called for a header row that does not match the schema" do
        assert_raises(IOStreams::Errors::InvalidHeader) do
          stream.schema(schema).writer(:line) { |io| io << "height" }
        end

        assert_empty store.events
      end

      it "is not called for a file without a header row" do
        stream.format(:json).writer(:hash) { |io| io << {"name" => "Jack"} }

        assert_equal [[:slice, ['{"name":"Jack"}']]], store.events
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
        small = Store.new(slice_size: 1)
        IOStreams.stream(small).schema(schema).writer(:hash) do |io|
          io << {"name" => "Jack", "age" => 21}
          io << {"name" => "Jill", "age" => 22}
        end
        records = small.slices.flat_map do |slice|
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
        small = Store.new(slice_size: 2)
        assert_raises(RuntimeError) do
          IOStreams.stream(small).writer(:line) do |io|
            io << "name" << "Jack" << "Jill" << "Bob"
            raise "failed"
          end
        end

        assert_equal [%w[Jack Jill]], small.slices.collect(&:to_a)
      end
    end

    describe "validate:" do
      it "parses each row, and raises for a value that is not valid, after the slices before it" do
        small = Store.new(slice_size: 1)
        assert_raises(IOStreams::Errors::InvalidValue) do
          IOStreams.stream(small).schema(schema).writer(:line, validate: true) do |io|
            io << "name,age" << "Jack,21" << "Jill,abc"
          end
        end

        assert_equal [%w[Jack,21]], small.slices.collect(&:to_a)
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

          small = Store.new(slice_size: 1)

          assert_equal 3, IOStreams.stream(small).schema(schema).copy_from(path, mode: :line)
          assert_equal [%w[Jack,21], ["\"Jill\nSmith\",22"]], small.slices.collect(&:to_a)
        end
      end

      it "copies the records of a file, rendered by the schema of the stream" do
        source = IOStreams.stream(StringIO.new("AGE,Name\n21,Jack\n")).format(:csv)
        stream.schema(schema).copy_from(source, mode: :hash)

        assert_equal [[%w[name age], :csv, %w[Jack,21]]], written
      end

      it "copies the lines in the format of the source, which the slices carry" do
        source = IOStreams.stream(StringIO.new("{\"name\":\"Jack\"}\n")).format(:json)
        stream.copy_from(source, mode: :line)
        psv = IOStreams.stream(StringIO.new("name|age\nJack|21\n")).format(:psv)
        stream.copy_from(psv, mode: :line)

        assert_equal [[nil, :json, ['{"name":"Jack"}']], [%w[name age], :psv, %w[Jack|21]]], written
        assert_nil stream.format
      end

      it "raises when the stream has a format other than that of the lines of the source, before it is read" do
        source = IOStreams.stream(StringIO.new("{\"name\":\"Jack\"}\n")).format(:json)
        error  = assert_raises(ArgumentError) { stream.format(:csv).copy_from(source, mode: :line) }

        assert_match(/in the :json format of their source, not :csv/, error.message)
        assert_equal 0, source.send(:io_stream).pos
      end

      it "copies the lines in the format of the stream when the source has none" do
        stream.format(:psv).copy_from(StringIO.new("name|age\nJack|21\n"), mode: :line)

        assert_equal [[%w[name age], :psv, %w[Jack|21]]], written
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

        assert_equal "Unknown option :delimiter for the :hash mode. Valid options: :validate.", error.message
      end

      it "raises for size:, since the store decides the size of its slices" do
        error = assert_raises(ArgumentError) { stream.writer(:line, size: 2) { nil } }

        assert_equal "Unknown option :size for the :line mode. Valid options: :validate.", error.message
      end

      it "raises for a slice size of the store that is not a positive Integer, before the block is called" do
        error = assert_raises(ArgumentError) do
          IOStreams.stream(Store.new(slice_size: 0)).writer(:line) { flunk("called the block") }
        end

        assert_equal "Invalid slice_size 0 of SliceTargetStreamTest::Store: return the number of rows of each slice",
                     error.message
      end

      it "raises for a validate that is not true or false" do
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

      it "raises for an encoding, or an option of it other than replace:, since the rows are UTF-8 text" do
        message = "Only `replace:` can be set with #encoding on a slice target, since it holds the rows of slices as " \
                  "UTF-8 text rather than bytes"

        assert_equal message, assert_raises(ArgumentError) { stream.encoding("UTF-8") }.message
        assert_equal message, assert_raises(ArgumentError) { stream.encoding(replace: "", cleaner: :printable) }.message
        assert_raises(ArgumentError) { stream.encoding(replace: 1) }
        assert_nil stream.encoding(replace: "").encoding
      end

      it "raises for a format whose rows are not lines" do
        error = assert_raises(ArgumentError) { stream.format(:parquet).writer(:hash) { nil } }

        assert_equal "The :parquet format has no lines, so its rows cannot be written to a slice target", error.message
      end
    end

    describe "#file_name" do
      it "raises, since a store has no file whose streams it would apply" do
        error = assert_raises(ArgumentError) { stream.file_name("people.csv.pgp") }

        assert_match(/has no file name/, error.message)
        assert_raises(ArgumentError) { stream.file_name = "people.csv" }
      end

      it "returns nil" do
        assert_nil stream.file_name
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
