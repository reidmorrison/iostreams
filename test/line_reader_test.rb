# frozen_string_literal: true

require_relative "test_helper"

class LineReaderTest < Minitest::Test
  # Returns blocks of the data tagged with an encoding, as when reading through an encode stream, but without
  # keeping its characters whole.
  class EncodedReader
    def initialize(data, encoding)
      @io       = StringIO.new(data.b)
      @encoding = encoding
    end

    def read(size)
      @io.read(size)&.force_encoding(@encoding)
    end
  end

  describe IOStreams::Line::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "text.txt")
    end

    let :csv_file do
      File.join(File.dirname(__FILE__), "files", "embedded_lines_test.csv")
    end

    let :unclosed_quote_file do
      File.join(File.dirname(__FILE__), "files", "unclosed_quote_test.csv")
    end

    let :unclosed_quote_file2 do
      File.join(File.dirname(__FILE__), "files", "unclosed_quote_test2.csv")
    end

    let :unclosed_quote_large_file do
      File.join(File.dirname(__FILE__), "files", "unclosed_quote_large_test.csv")
    end

    let :data do
      data = []
      File.open(file_name, "rt") do |file|
        data << file.readline.strip until file.eof?
      end
      data
    end

    # Test file has embedded new lines in row 2, 3 and 4
    #
    #  name, description, zip
    # "\nJack","Firstname is Jack","234567"
    # "John","Firstname\nis John","234568"
    # "Zack","Firstname is Zack","234568\n"
    #
    describe "embedded_within_quotes" do
      describe "csv file" do
        it "fails to keep embedded lines if flag is not set" do
          lines = []
          IOStreams::Line::Reader.file(csv_file) do |io|
            io.each do |line|
              lines << line
            end
          end

          expected = [
            "name, description, zip",
            '"',
            'Jack","Firstname is Jack","234567"',
            '"John","Firstname',
            'is John","234568"',
            '"Zack","Firstname is Zack","234568',
            '"'
          ]

          assert_equal expected, lines
        end

        it "keeps embedded lines if flag is set" do
          lines = []
          IOStreams::Line::Reader.file(csv_file, embedded_within: '"') do |io|
            io.each do |line|
              lines << line
            end
          end

          expected = [
            "name, description, zip",
            %("\nJack","Firstname is Jack","234567"),
            %("John","Firstname\nis John","234568"),
            %("Zack","Firstname is Zack","234568\n")
          ]

          assert_equal expected, lines
        end

        it "keeps a field with many embedded lines" do
          embedded = Array.new(1_000) { |i| "line #{i}" }.join("\n")
          input    = StringIO.new("\"#{embedded}\",x\nnext,\"\"\"quoted\"\"\"\n")
          lines    = []
          IOStreams::Line::Reader.stream(input, embedded_within: '"') do |io|
            io.each { |line| lines << line }
          end

          assert_equal ["\"#{embedded}\",x", "next,\"\"\"quoted\"\"\""], lines
        end

        it "raises error for unbalanced quotes" do
          exc = assert_raises(IOStreams::Errors::MalformedDataError) do
            IOStreams::Line::Reader.file(unclosed_quote_file, embedded_within: '"') do |io|
              io.each { |line| line }
            end
          end
          assert_includes exc.message, "Unbalanced delimited field, delimiter:"
        end

        it "raises error for unclosed quote" do
          exc = assert_raises(IOStreams::Errors::MalformedDataError) do
            IOStreams::Line::Reader.file(unclosed_quote_file2, embedded_within: '"') do |io|
              io.each { |line| line }
            end
          end
          assert_includes exc.message, "Unbalanced delimited field, delimiter:"
        end

        it "limits an unbalanced line by its size in bytes" do
          # 200 lines of a two byte character are 400 characters, but 600 bytes, which exceeds
          # the limit of 10 times the 51 byte buffer before the closing quote is reached.
          input = EncodedReader.new("\"#{"\u00e9\n" * 200}end\"\n", Encoding::UTF_8)
          exc   = assert_raises(IOStreams::Errors::MalformedDataError) do
            IOStreams::Line::Reader.stream(input, embedded_within: '"', buffer_size: 51) do |io|
              io.each { |line| line }
            end
          end

          assert_includes exc.message, "Unbalanced delimited field, delimiter:"
        end

        it "raises error for unclosed quote before eof" do
          exc = assert_raises(IOStreams::Errors::MalformedDataError) do
            IOStreams::Line::Reader.file(unclosed_quote_large_file, embedded_within: '"', buffer_size: 20) do |io|
              io.each { |line| line }
            end
          end
          assert_includes exc.message, "Unbalanced delimited field, delimiter:"
        end
      end
    end

    describe "invalid encoding" do
      def read_lines(data, **args)
        lines = []
        exc   = assert_raises(IOStreams::Errors::InvalidEncoding) do
          IOStreams::Encode::Reader.stream(StringIO.new(data.b)) do |text|
            IOStreams::Line::Reader.stream(text, **args) { |io| io.each { |line| lines << line } }
          end
        end
        [lines, exc]
      end

      it "returns the lines before an invalid character and raises with its line number" do
        lines, exc = read_lines("first\nsecond\nthi\xFFrd\nfourth\n")

        assert_equal %w[first second], lines
        assert_equal 3, exc.line_number
        assert_equal 16, exc.byte_offset
        assert_equal "\"\\xFF\" is not valid UTF-8 at byte offset 16 on line 3", exc.message
      end

      it "counts the lines read in earlier blocks" do
        lines, exc = read_lines("#{"line\n" * 100}bad\xFF\n", buffer_size: 7)

        assert_equal 100, lines.size
        assert_equal 101, exc.line_number
        assert_equal 503, exc.byte_offset
      end

      it "counts the lines within an embedded field" do
        lines, exc = read_lines("a,\"one\ntwo\"\nb,\"x\ny\xFF\"\n", embedded_within: '"')

        assert_equal ["a,\"one\ntwo\""], lines
        assert_equal 4, exc.line_number
      end

      it "finds the line on the first line" do
        lines, exc = read_lines("\xFF\n")

        assert_empty lines
        assert_equal 1, exc.line_number
        assert_equal 0, exc.byte_offset
      end

      it "counts the lines that were read while detecting the line endings" do
        # The first block ends with "\r", so the reader reads the next block to tell "\r" from "\r\n".
        lines, exc = read_lines("first\rsecond\r\xFF\r")

        assert_empty lines
        assert_equal 3, exc.line_number
        assert_equal 13, exc.byte_offset
      end

      it "keeps the line number that it was given first" do
        error             = IOStreams::Errors::InvalidEncoding.new("\"\\xFF\" is not valid UTF-8", byte_offset: 7)
        error.line_number = 3
        error.line_number = 5

        assert_equal 3, error.line_number
        assert_equal "\"\\xFF\" is not valid UTF-8 at byte offset 7 on line 3", error.message
      end

      it "names the line when reading a path" do
        exc = assert_raises(Encoding::UndefinedConversionError) do
          IOStreams.stream(StringIO.new("name,age\nJos\xE9,32\n".b)).each(:hash) { |hash| hash }
        end

        assert_equal "\"\\xE9\" is not valid UTF-8 at byte offset 12 on line 2", exc.message
      end
    end

    describe "#each" do
      it "each_line file" do
        lines = []
        count = IOStreams::Line::Reader.file(file_name) do |io|
          io.each { |line| lines << line }
        end

        assert_equal data, lines
        assert_equal data.size, count
      end

      it "each_line stream" do
        lines = []
        count = File.open(file_name) do |file|
          IOStreams::Line::Reader.stream(file) do |io|
            io.each { |line| lines << line }
          end
        end

        assert_equal data, lines
        assert_equal data.size, count
      end

      it "reads blocks of the default size for a buffer_size of nil, as when it is not supplied" do
        lines = []
        IOStreams.stream(StringIO.new(data.join("\n"))).each(:line, buffer_size: nil) { |line| lines << line }

        assert_equal data, lines
        assert_equal IOStreams::Line::Reader::DEFAULT_BUFFER_SIZE, IOStreams::Line::Reader.new(StringIO.new("a")).buffer_size
      end

      it "raises for a buffer_size that is not a positive Integer" do
        [0, -1, "64"].each do |buffer_size|
          error = assert_raises(ArgumentError) { IOStreams::Line::Reader.new(StringIO.new("a\n"), buffer_size: buffer_size) }

          assert_includes error.message, "Invalid buffer_size #{buffer_size.inspect}"
        end
      end

      ["\r\n", "\n", "\r"].each do |delimiter|
        it "autodetect delimiter: #{delimiter.inspect}" do
          lines  = []
          stream = StringIO.new(data.join(delimiter))
          count  = IOStreams::Line::Reader.stream(stream, buffer_size: 15) do |io|
            io.each { |line| lines << line }
          end

          assert_equal data, lines
          assert_equal data.size, count
        end

        it "single read autodetect delimiter: #{delimiter.inspect}" do
          lines  = []
          stream = StringIO.new(data.join(delimiter))
          count  = IOStreams::Line::Reader.stream(stream) do |io|
            io.each { |line| lines << line }
          end

          assert_equal data, lines
          assert_equal data.size, count
        end
      end

      describe "a file whose first line ends with \"\\r\\n\"" do
        # Returns [Array<String>] the lines read from the data, in blocks of the supplied size.
        def lines_of(data, buffer_size: nil, **)
          lines = []
          IOStreams::Line::Reader.stream(StringIO.new(data), buffer_size: buffer_size, **) do |io|
            io.each { |line| lines << line }
          end
          lines
        end

        it "also ends a line at a \"\\n\" without a \"\\r\", and keeps \"\\r\\n\" as its delimiter" do
          data = "name,zip\r\nJack,12345\nJill,98101\r\nBob,10001"

          IOStreams::Line::Reader.stream(StringIO.new(data)) { |io| assert_equal "\r\n", io.delimiter }
          [nil, 1, 2, 3, 7].each do |buffer_size|
            assert_equal ["name,zip", "Jack,12345", "Jill,98101", "Bob,10001"], lines_of(data, buffer_size: buffer_size)
          end
        end

        it "keeps a \"\\r\" that does not end a line" do
          assert_equal ["a,b", "c\rd", "e"], lines_of("a,b\r\nc\rd\ne\r")
        end

        it "keeps the line break within a quoted value as it is" do
          data = "a,b\r\n\"one\r\ntwo\",1\r\n\"three\nfour\",2\n"

          assert_equal ["a,b", "\"one\r\ntwo\",1", "\"three\nfour\",2"], lines_of(data, embedded_within: "\"")
        end

        it "only ends a line at \"\\r\\n\" when it is the supplied delimiter" do
          assert_equal %W[a b\nc], lines_of("a\r\nb\nc\r\n", delimiter: "\r\n")
        end

        it "reads every record of a CSV file whose lines end with \"\\r\\n\" and \"\\n\"" do
          records = []
          IOStreams.stream(StringIO.new("name,zip\r\nJack,12345\nJill,98101\r\n")).each(:hash) { |record| records << record }

          assert_equal [{"name" => "Jack", "zip" => "12345"}, {"name" => "Jill", "zip" => "98101"}], records
        end
      end

      ["@", "BLAH"].each do |delimiter|
        it "reads delimited #{delimiter.inspect}" do
          lines  = []
          stream = StringIO.new(data.join(delimiter))
          count  = IOStreams::Line::Reader.stream(stream, buffer_size: 15, delimiter: delimiter) do |io|
            io.each { |line| lines << line }
          end

          assert_equal data, lines
          assert_equal data.size, count
        end
      end

      it "is Enumerable, as a reader of records is" do
        lines = IOStreams.stream(StringIO.new("first\nsecond\nthird\n")).reader(:line) { |io| io.collect(&:upcase) }

        assert_equal %w[FIRST SECOND THIRD], lines
        assert_equal %w[first second], IOStreams.stream(StringIO.new("first\nsecond\nthird\n")).reader(:line) { |io| io.first(2) }
      end

      it "returns UTF-8 lines when characters and the delimiter are split across blocks" do
        data  = "Jos\u00e9\r\nZ\u00fcrich\r\n\u{1F600}"
        lines = []
        IOStreams::Line::Reader.stream(EncodedReader.new(data, Encoding::UTF_8), buffer_size: 3) do |io|
          assert_equal "\r\n", io.delimiter
          assert_equal Encoding::UTF_8, io.delimiter.encoding
          io.each { |line| lines << line }
        end

        assert_equal ["Jos\u00e9", "Z\u00fcrich", "\u{1F600}"], lines
        lines.each { |line| assert_equal Encoding::UTF_8, line.encoding }
      end

      it "splits Shift_JIS lines between whole characters" do
        # The second byte of the character "\x81\x7C" is the byte of "|".
        data  = "\x81\x7C|x".dup.force_encoding(Encoding::Shift_JIS)
        lines = []
        IOStreams::Line::Reader.stream(EncodedReader.new(data, Encoding::Shift_JIS), delimiter: "|") do |io|
          io.each { |line| lines << line }
        end

        assert_equal ["\x81\x7C", "x"].map { |line| line.dup.force_encoding(Encoding::Shift_JIS) }, lines
      end

      it "reads binary delimited" do
        delimiter = "\x01"
        lines     = []
        stream    = StringIO.new(data.join(delimiter).encode("ASCII-8BIT"))
        count     = IOStreams::Line::Reader.stream(stream, buffer_size: 15, delimiter: delimiter) do |io|
          io.each { |line| lines << line }
        end

        assert_equal data, lines
        assert_equal data.size, count
      end

      describe "#readline" do
        let(:short_line) { "0123456789" }
        let(:longer_line) { "ABCDEFGHIJKLMNOPQRSTUVWXYZ" }
        let(:delimiter) { "\r\n" }

        it "reads delimiter in first block, no delimiter at end" do
          data        = [short_line, longer_line].join(delimiter)
          buffer_size = short_line.length + delimiter.size + (longer_line.size / 2)

          stream = StringIO.new(data)
          IOStreams::Line::Reader.stream(stream, buffer_size: buffer_size) do |io|
            refute_predicate io, :eof?
            assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }

            assert_equal short_line, io.readline
            assert_equal longer_line, io.readline

            assert_predicate io, :eof?
            assert_nil io.readline
          end
        end

        it "reads delimiter in second block, no delimiter at end" do
          data        = [longer_line, short_line, short_line].join(delimiter)
          buffer_size = (longer_line.length + delimiter.size + 5) / 2

          stream = StringIO.new(data)
          IOStreams::Line::Reader.stream(stream, buffer_size: buffer_size) do |io|
            refute_predicate io, :eof?
            assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
            assert_equal longer_line, io.readline
            assert_equal short_line, io.readline
            assert_equal short_line, io.readline
            assert_predicate io, :eof?
            assert_nil io.readline
          end
        end

        it "reads delimiter split across first and second blocks" do
          data        = [longer_line, short_line, short_line].join(delimiter)
          buffer_size = longer_line.length + 1

          stream = StringIO.new(data)
          IOStreams::Line::Reader.stream(stream, buffer_size: buffer_size) do |io|
            refute_predicate io, :eof?
            assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
            assert_equal longer_line, io.readline
            assert_equal short_line, io.readline
            assert_equal short_line, io.readline
            assert_predicate io, :eof?
            assert_nil io.readline
          end
        end

        it "reads file with no matching delimiter" do
          delimiter   = "@"
          data        = [longer_line, short_line, longer_line].join(delimiter) + delimiter
          buffer_size = longer_line.length + 1

          stream = StringIO.new(data)
          IOStreams::Line::Reader.stream(stream, buffer_size: buffer_size) do |io|
            refute_predicate io, :eof?
            assert_equal "\n", io.delimiter, -> { io.delimiter.ai }
            assert_equal data, io.readline
            assert_predicate io, :eof?
            assert_nil io.readline
          end
        end

        it "reads small file with no matching delimiter" do
          data        = short_line
          buffer_size = short_line.length + 100

          stream = StringIO.new(data)
          IOStreams::Line::Reader.stream(stream, buffer_size: buffer_size) do |io|
            refute_predicate io, :eof?
            assert_equal "\n", io.delimiter, -> { io.delimiter.ai }
            assert_equal short_line, io.readline
            assert_predicate io, :eof?
            assert_nil io.readline
          end
        end

        it "reads last line with the delimiter as the last character" do
          delimiter   = "@"
          data        = [longer_line, short_line, longer_line].join(delimiter) + delimiter
          buffer_size = longer_line.length + 1

          stream = StringIO.new(data)
          IOStreams::Line::Reader.stream(stream, buffer_size: buffer_size, delimiter: delimiter) do |io|
            refute_predicate io, :eof?
            assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
            assert_equal longer_line, io.readline
            assert_equal short_line, io.readline
            assert_equal longer_line, io.readline
            assert_nil io.readline
            assert_predicate io, :eof?
          end
        end

        it "reads last line with the multi-byte delimiter as the last bytes" do
          data        = [longer_line, short_line, longer_line].join(delimiter) + delimiter
          buffer_size = longer_line.length + 1

          stream = StringIO.new(data)
          IOStreams::Line::Reader.stream(stream, buffer_size: buffer_size) do |io|
            refute_predicate io, :eof?
            assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
            assert_equal longer_line, io.readline
            assert_equal short_line, io.readline
            assert_equal longer_line, io.readline
            assert_nil io.readline
            assert_predicate io, :eof?
          end
        end

        describe "read 1 char at a time" do
          let(:buffer_size) { 1 }

          it "delimiter at the end" do
            data = [longer_line, short_line, longer_line].join(delimiter) + delimiter

            stream = StringIO.new(data)
            IOStreams::Line::Reader.stream(stream, buffer_size: buffer_size) do |io|
              refute_predicate io, :eof?
              assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
              assert_equal longer_line, io.readline
              assert_equal short_line, io.readline
              assert_equal longer_line, io.readline
              assert_nil io.readline
              assert_predicate io, :eof?
            end
          end

          it "no delimiter at the end" do
            data = [longer_line, short_line, longer_line].join(delimiter)

            stream = StringIO.new(data)
            IOStreams::Line::Reader.stream(stream, buffer_size: buffer_size) do |io|
              refute_predicate io, :eof?
              assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
              assert_equal longer_line, io.readline
              assert_equal short_line, io.readline
              assert_equal longer_line, io.readline
              assert_nil io.readline
              assert_predicate io, :eof?
            end
          end
        end

        it "reads empty file" do
          stream = StringIO.new

          IOStreams::Line::Reader.stream(stream) do |io|
            assert_predicate io, :eof?
            assert_nil io.readline
            assert_equal(0, io.each { |line| flunk("Read the line #{line.inspect} from an empty file") })
          end
        end

        it "prevents denial of service" do
          data   = "#{'a' * IOStreams::Line::Reader::MAX_BLOCKS_MULTIPLIER}a"
          stream = StringIO.new(data)
          assert_raises IOStreams::Errors::DelimiterNotFound do
            IOStreams::Line::Reader.stream(stream, buffer_size: 1) do |io|
              # Opening the reader is enough to trigger the error.
            end
          end
        end
      end
    end
  end
end
