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
      @events << [:slice, slice.rows]
    end
  end

  describe IOStreams::Slice::TargetStream do
    let(:store) { Store.new }
    let(:schema) { {"fields" => [{"name" => "name"}, {"name" => "age", "type" => "integer"}]} }
    let(:stream) { IOStreams.stream(store) }

    # Returns [Array] the header row, format and rows of each slice in the store.
    def written(target = store)
      target.slices.collect { |slice| [slice.header, slice.format, slice.rows] }
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
            (@stored ||= []) << slice.rows
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
            push(slice.rows)
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

        assert_equal [%w[Jack]], small.slices.collect(&:rows)
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

      it "gives each slice the line that its first row starts on, as reading the file gives it" do
        small = Store.new(slice_size: 2)
        lines = ["", "name,note", "Jack,\"line 1", "line 2\"", "", "Jill,ok", "Bob,x", "Ann,y"]
        IOStreams.stream(small).writer(:line) { |io| lines.each { |line| io << line } }

        assert_equal [3, 6, 8], small.slices.map(&:line_number)
        assert_equal [1, 3, 5], small.slices.map(&:record_number)
      end

      it "numbers the lines of a line that holds line breaks" do
        small = Store.new(slice_size: 1)
        IOStreams.stream(small).writer(:line) { |io| io << "name\nJack" << "Jill\n\nBob" }

        assert_equal [2, 3, 4, 5], small.slices.map(&:line_number)
        assert_equal [1, 2, 3, 4], small.slices.map(&:record_number)
      end

      it "gives each row the line that it starts on, after a row that holds a quoted line break" do
        large = Store.new(slice_size: 5)
        IOStreams.stream(large).writer(:line) { |io| io << "name,note" << "Jack,\"line 1\nline 2\"" << "Jill,ok" }

        assert_equal [[%(Jack,"line 1\nline 2"), 2, 1], ["Jill,ok", 4, 2]], large.slices.first.each.to_a
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

          assert_equal [%w[Jack]], small.slices.collect(&:rows)
        end

        it "reads the bytes of a binary line as UTF-8" do
          stream.writer(:line) { |io| io << "name".b << "Jöe".b }

          assert_equal [[%w[name], :csv, %w[Jöe]]], written
          assert_equal Encoding::UTF_8, store.slices.first[0].encoding
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
          assert(store.slices.first.rows.all? { |row| row.encoding == Encoding::UTF_8 })
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

        it "raises InvalidEncoding on the line of a character that UTF-8 does not have" do
          error = assert_raises(IOStreams::Errors::InvalidEncoding) do
            stream.writer(:line) { |io| io << "name,age" << "Jack,21" << "a\x81b,3".dup.force_encoding("Windows-1252") }
          end

          assert_equal "\"\\x81\" in WINDOWS-1252 has no UTF-8 character at byte offset 18 on line 3", error.message
          assert_equal "\x81".b, error.error_char
          assert_equal Encoding::Windows_1252, error.source_encoding
          assert_equal Encoding::UTF_8, error.destination_encoding
        end

        it "replaces a character that UTF-8 does not have with replace:" do
          stream.encoding(replace: "?").writer(:line) do |io|
            io << "name,age" << "a\x81b,3".dup.force_encoding("Windows-1252")
          end

          assert_equal [[%w[name age], :csv, ["a?b,3"]]], written
        end

        it "names the byte offset within the UTF-8 text of a line in another encoding, as the file holds it" do
          shift_jis = "x\n\x82\xA0y,\xFF1".dup.force_encoding("Shift_JIS")
          error     = assert_raises(IOStreams::Errors::InvalidEncoding) do
            stream.writer(:line) { |io| io << "name,age" << shift_jis }
          end
          file = read_error(["name,age", "x", "\xE3\x81\x82y,\xFF1".b])

          assert_equal [16, 3], [error.byte_offset, error.line_number]
          assert_equal [file.byte_offset, file.line_number], [error.byte_offset, error.line_number]
        end

        it "numbers the line of a converted line as the line reader does, which a lone return does not end" do
          line  = "\"a\rb\",\xFF"
          error = assert_raises(IOStreams::Errors::InvalidEncoding) do
            stream.writer(:line) { |io| io << "name,age" << line.dup.force_encoding("Windows-31J") }
          end
          file = read_error(["name,age", line.b])

          assert_equal [15, 2], [error.byte_offset, error.line_number]
          assert_equal [file.byte_offset, file.line_number], [error.byte_offset, error.line_number]
        end

        it "keeps a byte order mark at the start of a line that is kept for its line ending" do
          bom = "\xEF\xBB\xBF"
          stream.writer(:line) { |io| io << "name,age" << "#{bom}\"Ja\nck\",21" << "#{bom}Jill,22" }

          assert_equal [[%w[name age], :csv, ["#{bom}\"Ja\nck\",21", "#{bom}Jill,22"]]], written
        end

        it "adds the rows split from text that is kept as UTF-8 text" do
          stream.writer(:line) { |io| io << "name,age" << "\"J\xC3\xB6\nck\",21" << [1, 2].join(",") }

          assert_equal [[%w[name age], :csv, ["\"Jö\nck\",21", "1,2"]]], written
          assert(store.slices.first.rows.all? { |row| row.encoding == Encoding::UTF_8 })
        end

        it "raises ArgumentError for replace: in the :array or :hash mode, which it does not apply to yet" do
          replacing = stream.format(:csv).encoding(replace: "?")
          message   = "`replace:`, set with #encoding, applies only to the lines written to a slice target in the " \
                      ":line mode, not to the :hash mode"

          assert_equal message, assert_raises(ArgumentError) { replacing.writer(:hash) { flunk } }.message
          assert_raises(ArgumentError) { replacing.writer(:array) { flunk } }
          assert_raises(ArgumentError) { replacing.copy_from(IOStreams.stream(StringIO.new("a\n1\n")), mode: :hash) }
          assert_empty store.slices
        end
      end

      describe "cleaner:" do
        # Yields the name of a file that holds the lines, each followed by a line ending, as a line writer writes them.
        def with_file(lines)
          Dir.mktmpdir do |dir|
            file_name = File.join(dir, "people.csv")
            File.binwrite(file_name, "#{lines.collect(&:b).join("\n")}\n")
            yield(file_name)
          end
        end

        # Returns [Array] the header row, format, and rows with their numbers, of each slice that reading the lines from a file
        # with the supplied options of #encoding gives.
        def read_slices(lines, **encoding)
          with_file(lines) do |file_name|
            slices = []
            IOStreams.path(file_name).encoding(**encoding).each(:slice, size: 100) do |slice|
              slices << [slice.header, slice.format, slice.each.to_a]
            end
            slices
          end
        end

        # Returns [IOStreams::Errors::InvalidEncoding] the error that reading the lines from a file raises with the
        # supplied options of #encoding.
        def read_error(lines, **encoding)
          with_file(lines) do |file_name|
            assert_raises(IOStreams::Errors::InvalidEncoding) do
              IOStreams.path(file_name).encoding(**encoding).each(:slice, size: 100) { nil }
            end
          end
        end

        it "cleans each row with a built-in rule, leaving the line written as it is" do
          line = +"Jack,a\tb"
          stream.format(:csv).encoding(cleaner: :printable, replace: "").writer(:line) do |io|
            io << "name,note"
            io << line
          end

          assert_equal [[%w[name note], :csv, ["Jack,ab"]]], written
          assert_equal "Jack,a\tb", line
        end

        it "gives the rows that reading the file with the cleaner gives, header row and blank rows included" do
          lines = ["na\x01me,note", "Jack,a\tb", "", "\x00", "Jill,\"c\x01\nd\"", "Bob,e\x7Ff"]
          stream.encoding(cleaner: :printable).writer(:line) { |io| lines.each { |line| io << line } }

          stored = store.slices.collect { |slice| [slice.header, slice.format, slice.each.to_a] }

          rows = [["Jack,ab", 2, 1], ["", 3, 2], ["", 4, 3], ["Jill,\"c\nd\"", 5, 4], ["Bob,ef", 7, 5]]

          assert_equal [[%w[name note], :csv, rows]], stored
          assert_equal read_slices(lines, cleaner: :printable), stored
        end

        it "keeps the line endings within a quoted value" do
          stream.encoding(cleaner: :printable).writer(:line) do |io|
            io << "name,note" << "Jack,\"a\x01\nb\"" << "Jill,\"c\r\nd\x7F\""
          end

          assert_equal [[%w[name note], :csv, ["Jack,\"a\nb\"", "Jill,\"c\r\nd\""]]], written
        end

        it "cleans each row with a Proc, such as with spaces for fixed width" do
          fixed  = {"fields" => [{"name" => "name", "width" => 10}, {"name" => "zip", "type" => "integer", "width" => 5}]}
          spaces = ->(data, _replace) { data.gsub(/[^[:print:]\r\n]/, " ") }
          stream.format(:fixed).schema(fixed).encoding(cleaner: spaces).writer(:line, validate: true) do |io|
            io << "Ja\x01ck     12345"
          end

          assert_equal [["Ja ck     12345"]], store.slices.collect(&:rows)
        end

        it "calls a Proc with a copy of each line written, so that it does not change the caller's line" do
          line    = +"Jack,a\x01b"
          cleaner = ->(data, _replace) { data.delete!("\x01") || data }
          stream.encoding(cleaner: cleaner).writer(:line) do |io|
            io << "name,note"
            io << line
            io << "Jill,c\x01d"
          end

          assert_equal [[%w[name note], :csv, ["Jack,ab", "Jill,cd"]]], written
          assert_equal "Jack,a\x01b", line
        end

        it "calls a Proc with each line written, before it is split into rows" do
          supplied = []
          cleaner  = lambda do |data, _replace|
            supplied << data
            data
          end
          stream.encoding(cleaner: cleaner).writer(:line) { |io| io << "name,note" << "Jack,a\nJill,\"b" << "c\"" }

          assert_equal ["name,note", "Jack,a\nJill,\"b", "c\""], supplied
          assert_equal [[%w[name note], :csv, ["Jack,a", "Jill,\"b\nc\""]]], written
        end

        it "raises ArgumentError when a Proc does not return a String, rather than store a blank row" do
          returns_nil = ->(data, _replace) { data.gsub!("\x01", "") }
          error       = assert_raises(ArgumentError) do
            stream.encoding(cleaner: returns_nil).writer(:line) { |io| io << "name,note" }
          end

          assert_equal "The cleaner set with #encoding returned nil rather than the cleaned text of the line as a String",
                       error.message

          returns_array = ->(data, _replace) { data.split(",") }
          error         = assert_raises(ArgumentError) do
            IOStreams.stream(store).encoding(cleaner: returns_array).writer(:line) { |io| io << "name,note" }
          end

          assert_match(/returned a Array rather than/, error.message)
          assert_empty store.slices
        end

        it "splits the rows by the quotes and line endings that the cleaner leaves, as reading the file does" do
          lines    = ["name,note", "Jack,a\x01b", "Jill,c", "Bob,d\x01e"]
          expected = {
            "\"" => [["Jack,a\"b\nJill,c\nBob,d\"e", 2, 1]],
            "\n" => [["Jack,a", 2, 1], ["b", 3, 2], ["Jill,c", 4, 3], ["Bob,d", 5, 4], ["e", 6, 5]]
          }
          expected.each_pair do |replace, rows|
            target = Store.new
            IOStreams.stream(target).encoding(cleaner: :replace_non_printable, replace: replace).writer(:line) do |io|
              lines.each { |line| io << line }
            end
            stored = target.slices.collect { |slice| [slice.header, slice.format, slice.each.to_a] }

            assert_equal [[%w[name note], :csv, rows]], stored, replace.inspect
            assert_equal read_slices(lines, cleaner: :replace_non_printable, replace: replace), stored, replace.inspect
          end
        end

        it "calls a Proc with replace:" do
          supplied = []
          cleaner  = lambda do |data, replace|
            supplied << replace
            data.upcase
          end
          stream.encoding(cleaner: cleaner, replace: "?").writer(:line) { |io| io << "name" << "jack" }

          assert_equal [[%w[NAME], :csv, ["JACK"]]], written
          assert_equal ["?", "?"], supplied
        end

        it "replaces the characters that are not printable with replace: for :replace_non_printable" do
          stream.encoding(cleaner: :replace_non_printable, replace: "?").writer(:line) do |io|
            io << "name,note" << "Jack,a\tb" << "Jill,\xFFc".b
          end

          assert_equal [[%w[name note], :csv, ["Jack,a?b", "Jill,?c"]]], written
        end

        it "raises InvalidEncoding at the byte offset of the text as written, as reading the file with the cleaner does" do
          lines = ["name,note", "Jack,a\x00\x00b", "Bob,\xFFx".b]
          error = assert_raises(IOStreams::Errors::InvalidEncoding) do
            stream.encoding(cleaner: :printable).writer(:line) { |io| lines.each { |line| io << line } }
          end

          assert_equal "\"\\xFF\" is not valid UTF-8 at byte offset 24 on line 3", error.message
          assert_equal read_error(lines, cleaner: :printable).message, error.message
        end

        it "raises at the byte offset of the text as written within a quoted value that is still open" do
          lines = ["name,note", "Jack,\"a\x00", "b\xFF\"".b]
          error = assert_raises(IOStreams::Errors::InvalidEncoding) do
            stream.encoding(cleaner: :printable).writer(:line) { |io| lines.each { |line| io << line } }
          end

          assert_equal [20, 3], [error.byte_offset, error.line_number]
          assert_equal read_error(lines, cleaner: :printable).message, error.message
        end

        it "cleans the lines copied in the :line mode" do
          source = IOStreams.stream(StringIO.new("name,note\nJack,a\tb\n")).format(:csv)
          stream.encoding(cleaner: :printable).copy_from(source, mode: :line)

          assert_equal [[%w[name note], :csv, ["Jack,ab"]]], written
        end

        it "raises ArgumentError in the :array or :hash mode, which it does not apply to yet" do
          cleaning = IOStreams.stream(store).encoding(cleaner: :printable)
          message  = "`cleaner:`, set with #encoding, applies only to the lines written to a slice target in the " \
                     ":line mode, not to the :hash mode"

          assert_equal message, assert_raises(ArgumentError) { cleaning.writer(:hash) { flunk } }.message
          assert_raises(ArgumentError) { cleaning.writer(:array) { flunk } }
          assert_raises(ArgumentError) { cleaning.copy_from(IOStreams.stream(StringIO.new("a\n1\n")), mode: :array) }

          both    = IOStreams.stream(store).encoding(cleaner: :printable, replace: "")
          message = "`replace:` and `cleaner:`, set with #encoding, apply only to the lines written to a slice target " \
                    "in the :line mode, not to the :array mode"

          assert_equal message, assert_raises(ArgumentError) { both.writer(:array) { flunk } }.message
          assert_empty store.slices
        end

        it "raises ArgumentError when it is set to a cleaner that is neither a built-in rule nor a Proc" do
          assert_raises(ArgumentError) { stream.encoding(cleaner: :unknown) }
          assert_raises(ArgumentError) { stream.encoding(cleaner: "printable") }
          assert_nil stream.setting(:encode)
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

      it "gives each row its record number, after the header row, and no line, since the rows are not lines of a file" do
        small = Store.new(slice_size: 2)
        IOStreams.stream(small).writer(:array) do |io|
          io << %w[name note]
          io << ["Jack", "line 1\nline 2"]
          io << %w[Jill ok]
          io << %w[Bob x]
        end

        assert_equal [nil, nil], small.slices.collect(&:line_number)
        assert_equal [1, 3], small.slices.collect(&:record_number)
        assert_equal([[nil, 1], [nil, 2]], small.slices.first.each.map { |_row, line, record| [line, record] })
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

    describe "the rows that a program writes" do
      let(:typed_schema) { {"fields" => [{"name" => "name"}, {"name" => "on", "type" => "date"}]} }

      # Returns [Array] the records of the supplied slice, read by the supplied schema.
      def read(slice, schema)
        list = []
        IOStreams.stream(slice).schema(schema).each(:hash) { |record| list << record }
        list
      end

      it "are typed in a format whose rows hold the values themselves, and each one is a record" do
        stream.format(:hash).schema(typed_schema).writer(:hash) { |io| io << {"name" => "Jack", "on" => Date.new(2026, 1, 2)} }
        slice = store.slices.first

        assert_predicate slice, :typed?
        refute_predicate slice, :blank_rows?
        assert_equal [{"name" => "Jack", "on" => Date.new(2026, 1, 2)}], slice.rows
      end

      it "are typed in the :array format too, after their header row" do
        stream.format(:array).schema(typed_schema).writer(:array) { |io| io << ["Jack", Date.new(2026, 1, 2)] }
        slice = store.slices.first

        assert_predicate slice, :typed?
        assert_equal %w[name on], slice.header
        assert_equal [["Jack", Date.new(2026, 1, 2)]], slice.rows
      end

      it "are not typed in a format of text, whose values the schema converts when they are read, but are each a record" do
        stream.schema(typed_schema).writer(:hash) { |io| io << {"name" => "Jack", "on" => Date.new(2026, 1, 2)} }
        slice = store.slices.first

        refute_predicate slice, :typed?
        refute_predicate slice, :blank_rows?
        assert_equal [{"name" => "Jack", "on" => Date.new(2026, 1, 2)}], read(slice, typed_schema)
      end

      it "are not typed when they are written as lines, which are the blank rows of a file" do
        stream.writer(:line) { |io| io << "name,on" << "Jack,2026-01-02" }
        slice = store.slices.first

        refute_predicate slice, :typed?
        assert_predicate slice, :blank_rows?
      end

      it "are read back as they were written, without converting their values again" do
        stream.format(:hash).schema(typed_schema).writer(:hash) do |io|
          io << {"name" => "Jack", "on" => Date.new(2026, 1, 2)}
          io << {"name" => nil, "on" => nil}
        end

        assert_equal [{"name" => "Jack", "on" => Date.new(2026, 1, 2)}, {"name" => nil, "on" => nil}],
                     read(store.slices.first, typed_schema)
      end

      it "are read as a store kept them, once stored and turned back from the Hash of the slice" do
        stream.format(:hash).schema(typed_schema).writer(:hash) { |io| io << {"name" => "Jack", "on" => Date.new(2026, 1, 2)} }
        hash = store.slices.first.to_h
        # A store that does not keep the type of a value, as BSON holds a Date as a Time, and a duration as its seconds.
        stored = hash.merge("rows" => [{"name" => "Jack", "on" => Time.utc(2026, 1, 2), "wait" => 300}])
        schema = typed_schema.merge("fields" => typed_schema["fields"] + [{"name" => "wait", "type" => "duration"}])

        assert_equal({"typed" => true, "blank_rows" => false}, hash.slice("typed", "blank_rows"))
        assert_equal [{"name" => "Jack", "on" => Time.utc(2026, 1, 2), "wait" => 300}], read(IOStreams.slice(stored), schema)
      end

      it "are still matched to the fields of the schema by their keys" do
        slice  = IOStreams::Slice.new([{"Full Name" => "Jack", "age" => "21"}], format: :hash, typed: true)
        schema = {"fields" => [{"name" => "name", "aliases" => ["Full Name"]}, {"name" => "age", "type" => "integer"}]}

        assert_equal [{"name" => "Jack", "age" => "21"}], read(slice, schema)
        assert_raises(IOStreams::Errors::InvalidHeader) { read(slice, schema.merge("fieldsMatch" => "exact", "fields" => [{"name" => "name"}])) }
      end

      it "without a header row are read by the fields of the schema in order, which must be exact" do
        ranges = {"header" => false, "fields" => [{"name" => "first_id", "type" => "integer"}, {"name" => "last_id", "type" => "integer"}]}
        IOStreams.stream(store).format(:array).schema(ranges).writer(:array) { |io| io << [1, 100] << [101, 200] }
        slice    = store.slices.first
        in_order = {"fieldsMatch" => "exact", "fields" => [{"name" => "from"}, {"name" => "to"}]}

        assert_predicate slice, :typed?
        refute_predicate slice, :header?
        assert_equal [{"from" => 1, "to" => 100}, {"from" => 101, "to" => 200}], read(slice, in_order)
        assert_raises(ArgumentError) { read(slice, in_order.merge("fieldsMatch" => "equal")) }
        error = assert_raises(ArgumentError) { IOStreams.stream(slice).each(:hash) { nil } }
        assert_match(/set one, whose fields name them/, error.message)
      end

      it "are converted by the schema when the slice is not typed, such as a slice built of values" do
        slice = IOStreams::Slice.new([{"name" => "Jack", "age" => "21"}], format: :hash)

        assert_equal [{"name" => "Jack", "age" => 21}], read(slice, schema)
      end

      it "are typed and each a record when the slice is copied, see IOStreams::Slice#with_rows" do
        stream.format(:hash).schema(typed_schema).writer(:hash) { |io| io << {"name" => "Jack", "on" => Date.new(2026, 1, 2)} }
        copy = store.slices.first.with_rows([{"name" => "Jill", "on" => Time.utc(2026, 1, 3)}])

        assert_predicate copy, :typed?
        refute_predicate copy, :blank_rows?
        assert_equal [{"name" => "Jill", "on" => Time.utc(2026, 1, 3)}], read(copy, typed_schema)
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

        assert_equal [%w[Jack Jill]], small.slices.collect(&:rows)
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

        assert_equal [%w[Jack,21]], small.slices.collect(&:rows)
      end

      it "does not parse the rows by default" do
        stream.schema(schema).writer(:line) { |io| io << "name,age" << "Jill,abc" }

        assert_equal [%w[Jill,abc]], store.slices.collect(&:rows)
      end
    end

    describe "#copy_from" do
      it "copies the lines of a file, keeping a quoted value with a line break within its row" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.csv.gz")
          path.write("name,age\nJack,21\n\"Jill\nSmith\",22\n")

          small = Store.new(slice_size: 1)

          assert_equal 3, IOStreams.stream(small).schema(schema).copy_from(path, mode: :line)
          assert_equal [%w[Jack,21], ["\"Jill\nSmith\",22"]], small.slices.collect(&:rows)
          assert_equal [2, 3], small.slices.collect(&:line_number)
          assert_equal [1, 2], small.slices.collect(&:record_number)
        end
      end

      it "gives the lines copied from a spreadsheet no line, since they are not its rows, and their record numbers" do
        small = Store.new(slice_size: 5)
        IOStreams.stream(small).copy_from(File.join(__dir__, "files", "multiline_cell.xlsx"), mode: :line)

        assert_equal [[%(data 1,data 2,"more\ndata"), nil, 1]], small.slices.first.each.to_a
      end

      it "gives the rows copied in the :hash mode their record numbers and no line, as for a query" do
        small  = Store.new(slice_size: 1)
        source = IOStreams.stream(StringIO.new("name,note\nJack,\"line 1\nline 2\"\nJill,ok\n")).format(:csv)
        IOStreams.stream(small).copy_from(source, mode: :hash)

        assert_equal [nil, nil], small.slices.collect(&:line_number)
        assert_equal [1, 2], small.slices.collect(&:record_number)
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

      it "raises for an encoding, or an option of it other than replace: and cleaner:, since the rows are UTF-8 text" do
        message = "Only `replace:` and `cleaner:` can be set with #encoding on a slice target, since it holds the rows " \
                  "of slices as UTF-8 text rather than bytes"

        assert_equal message, assert_raises(ArgumentError) { stream.encoding("UTF-8") }.message
        assert_equal message, assert_raises(ArgumentError) { stream.encoding("Windows-1252", cleaner: :printable) }.message
        assert_equal message, assert_raises(ArgumentError) { stream.encoding(encoding: "UTF-8", replace: "") }.message
        assert_raises(ArgumentError) { stream.encoding(replace: 1) }
        assert_nil stream.setting(:encode)
        assert_nil stream.encoding(replace: "", cleaner: :printable).encoding
        assert_equal({replace: "", cleaner: :printable}, stream.setting(:encode))
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
