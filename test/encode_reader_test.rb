# frozen_string_literal: true

require_relative "test_helper"
require "csv"

class EncodeReaderTest < Minitest::Test
  # Wraps an IO whose `#read` only accepts a single optional argument (arity -1).
  # The encode reader assigns a read-cache buffer based on arity, but the 2-arg
  # `read(size, buffer)` call then raises ArgumentError and must fall back.
  class OneArgReader
    def initialize(io)
      @io = io
    end

    def read(size = nil)
      @io.read(size)
    end
  end

  # Wraps an IO whose `#read` requires its size argument (arity 1), so no
  # read-cache buffer is ever assigned.
  class StrictReader
    def initialize(io)
      @io = io
    end

    def read(size)
      @io.read(size)
    end
  end

  describe IOStreams::Encode::Reader do
    let :bad_data do
      [
        "New M\xE9xico,NE".b,
        "good line",
        "New M\xE9xico,\x07SF".b
      ].join("\n").encode("BINARY")
    end

    let :cleansed_data do
      bad_data.gsub("\xE9".b, "")
    end

    let :stripped_data do
      cleansed_data.gsub("\x07", "")
    end

    describe "#read" do
      describe "replacement" do
        it "does not strip invalid characters" do
          input = StringIO.new(bad_data)

          IOStreams::Encode::Reader.stream(input, encoding: "UTF-8") do |io|
            error = assert_raises(IOStreams::Errors::InvalidEncoding) { io.read }

            assert_equal 5, error.byte_offset
          end
        end

        it "strips invalid characters" do
          input = StringIO.new(bad_data)
          data  =
            IOStreams::Encode::Reader.stream(input, encoding: "UTF-8", replace: "", &:read)

          assert_equal cleansed_data, data
          assert_equal Encoding::UTF_8, data.encoding
        end
      end

      describe "printable" do
        it "strips non-printable characters" do
          input = StringIO.new(bad_data)
          data  =
            IOStreams::Encode::Reader.stream(input, encoding: "UTF-8", cleaner: :printable, replace: "", &:read)

          assert_equal stripped_data, data
          assert_equal Encoding::UTF_8, data.encoding
        end
      end

      describe "buffered reads" do
        let :valid_data do
          ("abcdefghij\n" * 50).encode("UTF-8")
        end

        it "reads in chunks reusing the read-cache buffer" do
          # replace is nil and StringIO#read accepts (size, buffer), so the fast
          # path that reuses @read_cache_buffer is exercised on every read.
          input  = StringIO.new(valid_data.dup)
          result = +""
          IOStreams::Encode::Reader.stream(input, encoding: "UTF-8") do |io|
            while (chunk = io.read(7))
              result << chunk
            end
          end

          assert_equal valid_data, result
        end

        it "returns nil at end of file" do
          input = StringIO.new("")

          IOStreams::Encode::Reader.stream(input, encoding: "UTF-8") do |io|
            assert_nil io.read(10)
          end
        end

        it "falls back when the stream does not accept a buffer argument" do
          # OneArgReader#read has arity -1, so a buffer is assigned, but the
          # 2-arg call raises ArgumentError and the reader falls back to read(size).
          input  = OneArgReader.new(StringIO.new(valid_data.dup))
          result = +""
          IOStreams::Encode::Reader.stream(input, encoding: "UTF-8") do |io|
            while (chunk = io.read(7))
              result << chunk
            end
          end

          assert_equal valid_data, result
        end

        it "does not buffer when read requires its size argument" do
          # StrictReader#read has arity 1, so no read-cache buffer is assigned.
          input  = StrictReader.new(StringIO.new(valid_data.dup))
          result = +""
          IOStreams::Encode::Reader.stream(input, encoding: "UTF-8") do |io|
            while (chunk = io.read(7))
              result << chunk
            end
          end

          assert_equal valid_data, result
        end
      end

      describe "encoding conversion" do
        it "converts to the requested encoding" do
          input = StringIO.new("plain ascii text".encode("UTF-8"))
          data  = IOStreams::Encode::Reader.stream(input, encoding: "US-ASCII", &:read)

          assert_equal Encoding.find("US-ASCII"), data.encoding
          assert_equal "plain ascii text", data
        end
      end

      describe "cleaner" do
        it "replaces non-printable characters with the replace value" do
          input = StringIO.new("abcdef")
          data  =
            IOStreams::Encode::Reader.stream(input, encoding: "UTF-8", cleaner: :replace_non_printable, replace: "X", &:read)

          assert_equal "abcXdef", data
        end

        it "accepts a Proc cleaner" do
          upcase = ->(data, _replace) { data.upcase }
          input  = StringIO.new("hello")
          data   = IOStreams::Encode::Reader.stream(input, encoding: "UTF-8", cleaner: upcase, &:read)

          assert_equal "HELLO", data
        end

        it "raises for an unknown cleaner symbol" do
          input = StringIO.new("x")
          error = assert_raises(ArgumentError) do
            IOStreams::Encode::Reader.stream(input, cleaner: :unknown_rule, &:read)
          end

          assert_equal "Invalid cleansing rule :unknown_rule", error.message
        end

        it "raises for a cleaner that is neither a Symbol nor a Proc, rather than ignoring it" do
          error = assert_raises(ArgumentError) do
            IOStreams::Encode::Reader.stream(StringIO.new("x"), cleaner: "printable", &:read)
          end

          assert_includes error.message, %(Invalid cleaner "printable")
        end
      end

      describe "invalid data" do
        it "raises an error that answers what Encoding::UndefinedConversionError answers" do
          exc = assert_raises(Encoding::UndefinedConversionError) do
            IOStreams::Encode::Reader.stream(StringIO.new("ab\xE9cd".b), encoding: "UTF-8", &:read)
          end

          assert_instance_of IOStreams::Errors::InvalidEncoding, exc
          assert_equal "\xE9".b, exc.error_char
          assert_equal Encoding::BINARY, exc.source_encoding
          assert_equal Encoding::UTF_8, exc.destination_encoding
          assert_equal "ASCII-8BIT", exc.source_encoding_name
          assert_equal "UTF-8", exc.destination_encoding_name
        end

        it "keeps a character of another encoding that is split across reads after an invalid byte, with replace" do
          data   = "\xFF".b + "ab".b + "\u65E5cd".encode("Shift_JIS").b
          chunks = []
          IOStreams::Encode::Reader.stream(StringIO.new(data), encoding: "Shift_JIS:UTF-8", replace: "?") do |io|
            while (chunk = io.read(4))
              chunks << chunk
            end
          end

          assert_equal "?ab\u65E5cd", chunks.join
        end
      end

      describe "valid multi-byte characters" do
        let(:text) { "Jos\u00e9, M\u00fcnchen \u{1F600}" }

        it "reads them from binary data" do
          data = IOStreams::Encode::Reader.stream(StringIO.new(text.b), encoding: "UTF-8", &:read)

          assert_equal text, data
          assert_equal Encoding::UTF_8, data.encoding
        end

        it "keeps them when replacing invalid characters" do
          data = IOStreams::Encode::Reader.stream(StringIO.new("#{text}\xE9".b), encoding: "UTF-8", replace: "?", &:read)

          assert_equal "#{text}?", data
        end

        it "returns a character that is split across reads" do
          chunks = []
          IOStreams::Encode::Reader.stream(StringIO.new(text.b), encoding: "UTF-8") do |io|
            while (chunk = io.read(1))
              chunks << chunk
            end
          end

          assert_equal text, chunks.join
          chunks.each { |chunk| assert_predicate chunk, :valid_encoding? }
        end

        it "returns a character that is split across reads when replacing invalid characters" do
          chunks = []
          IOStreams::Encode::Reader.stream(StringIO.new(text.b), encoding: "UTF-8", replace: "") do |io|
            while (chunk = io.read(3))
              chunks << chunk
            end
          end

          assert_equal text, chunks.join
        end

        it "raises for an invalid character when reading in blocks" do
          assert_raises ::Encoding::UndefinedConversionError do
            IOStreams::Encode::Reader.stream(StringIO.new(bad_data), encoding: "UTF-8") do |io|
              while io.read(3)
              end
            end
          end
        end

        it "raises for an incomplete character at the end" do
          assert_raises ::Encoding::UndefinedConversionError do
            IOStreams::Encode::Reader.stream(StringIO.new("abc\xC3".b), encoding: "UTF-8") do |io|
              while io.read(2)
              end
            end
          end
        end

        it "raises with the byte offset of an invalid character" do
          exc = assert_raises(IOStreams::Errors::InvalidEncoding) do
            IOStreams::Encode::Reader.stream(StringIO.new(bad_data), encoding: "UTF-8", &:read)
          end

          assert_equal 5, exc.byte_offset
          assert_nil exc.line_number
          assert_equal "\"\\xE9\" is not valid UTF-8 at byte offset 5", exc.message
        end

        it "names the first of several invalid characters" do
          exc = assert_raises(IOStreams::Errors::InvalidEncoding) do
            IOStreams::Encode::Reader.stream(StringIO.new("ab\xFFcd\xFE".b), encoding: "UTF-8", &:read)
          end

          assert_equal "\"\\xFF\" is not valid UTF-8 at byte offset 2", exc.message
        end

        it "returns the data before an invalid character when reading in blocks, and raises on the next read" do
          IOStreams::Encode::Reader.stream(StringIO.new("abc\ndef\xFFgh".b), encoding: "UTF-8") do |io|
            assert_equal "abc\n", io.read(4)
            assert_equal "def", io.read(4)
            exc = assert_raises(IOStreams::Errors::InvalidEncoding) { io.read(4) }
            assert_equal 7, exc.byte_offset
            assert_raises(IOStreams::Errors::InvalidEncoding) { io.read(4) }
          end
        end

        it "raises with the byte offset of an incomplete character at the end" do
          exc = assert_raises(IOStreams::Errors::InvalidEncoding) do
            IOStreams::Encode::Reader.stream(StringIO.new("abc\xC3".b), encoding: "UTF-8") do |io|
              while io.read(2)
              end
            end
          end

          assert_equal 3, exc.byte_offset
        end

        it "replaces an incomplete character at the end" do
          data = IOStreams::Encode::Reader.stream(StringIO.new("abc\xC3".b), encoding: "UTF-8", replace: "?") do |io|
            chunks = []
            while (chunk = io.read(2))
              chunks << chunk
            end
            chunks.join
          end

          assert_equal "abc?", data
        end

        it "reads lines from a file where a character is split by the block size" do
          Tempfile.create(%w[iostreams .csv]) do |file|
            # The 65,536th byte is the first byte of "é", so the first block ends in the middle of it.
            file.binmode
            file.write("#{'x' * 65_534}\n#{"\u00e9,Jos\u00e9\n" * 3}".b)
            file.close
            lines = []
            IOStreams.path(file.path).encoding("UTF-8").each(:line) { |line| lines << line }

            assert_equal ["x" * 65_534, "\u00e9,Jos\u00e9", "\u00e9,Jos\u00e9", "\u00e9,Jos\u00e9"], lines
          end
        end
      end

      describe "buffer argument" do
        it "replaces and returns the supplied buffer" do
          buffer = +"previous"
          IOStreams::Encode::Reader.stream(StringIO.new("hello"), encoding: "UTF-8") do |io|
            assert_same buffer, io.read(3, buffer)
            assert_equal "hel", buffer
            assert_nil io.read(10, io.read(10, buffer))
            assert_empty buffer
          end
        end

        it "returns a new string from each read without a buffer" do
          IOStreams::Encode::Reader.stream(StringIO.new("hello"), encoding: "UTF-8") do |io|
            first = io.read(2)

            assert_equal "he", first
            io.read(2)

            assert_equal "he", first
          end
        end

        it "copies with IO.copy_stream" do
          output = StringIO.new
          IOStreams::Encode::Reader.stream(StringIO.new("Jos\u00e9".b), encoding: "UTF-8") { |io| IO.copy_stream(io, output) }

          assert_equal "Jos\u00e9", output.string.force_encoding("UTF-8")
        end

        it "returns a new string from each read with encoding: BINARY" do
          IOStreams::Encode::Reader.stream(StringIO.new("hello"), encoding: "BINARY") do |io|
            first = io.read(2)
            io.read(2)

            assert_equal "he", first
          end
        end
      end

      describe "data read as bytes" do
        let(:latin1) { "Jos\xE9,M\xE1laga".b }

        # Reads the supplied input with the encode reader in blocks of 4 bytes.
        def read_in_blocks(input, **args)
          chunks = []
          IOStreams::Encode::Reader.stream(input, **args) do |io|
            while (chunk = io.read(4))
              chunks << chunk
            end
          end
          chunks
        end

        it "returns binary data unchanged with encoding: BINARY" do
          chunks = read_in_blocks(StringIO.new(latin1), encoding: "BINARY")

          assert_equal latin1, chunks.join
          chunks.each { |chunk| assert_equal Encoding::BINARY, chunk.encoding }
        end

        it "keeps the characters of another encoding when reading in blocks" do
          data = read_in_blocks(StringIO.new(latin1), encoding: "ISO-8859-1").join

          assert_equal Encoding::ISO_8859_1, data.encoding
          assert_equal "Jos\u00e9,M\u00e1laga", data.encode("UTF-8")
        end

        it "treats data that the input stream tags with an encoding as bytes" do
          # For example, reading the whole of a gzip file returns data tagged with Encoding.default_external.
          input = StringIO.new(latin1.dup.force_encoding(Encoding::UTF_8))
          data  = IOStreams::Encode::Reader.stream(input, encoding: "ISO-8859-1", &:read)

          assert_equal "Jos\u00e9,M\u00e1laga", data.encode("UTF-8")
        end

        it "reads lines from a file unchanged with encoding: BINARY" do
          Tempfile.create(%w[iostreams .csv]) do |file|
            file.binmode
            file.write("name\nJos\xE9\n".b)
            file.close
            lines = []
            IOStreams.path(file.path).encoding("BINARY").each(:line) { |line| lines << line }

            assert_equal ["name", "Jos\xE9".b], lines
            assert_equal Encoding::BINARY, lines.last.encoding
          end
        end

        it "reads the whole of a gzip file the same as the same data in a plain file" do
          Dir.mktmpdir do |dir|
            IOStreams.path(dir, "data.txt").write(latin1)
            IOStreams.path(dir, "data.txt.gz").write(latin1)
            plain = IOStreams.path(dir, "data.txt").encoding("Windows-1252").read
            gzip  = IOStreams.path(dir, "data.txt.gz").encoding("Windows-1252").read

            assert_equal plain, gzip
            assert_equal "Jos\u00e9,M\u00e1laga", gzip.encode("UTF-8")
          end
        end
      end

      describe "byte order mark" do
        let(:with_byte_order_mark) { "\xEF\xBB\xBFname,city".b }

        it "is removed from the start of UTF-8 data" do
          data = IOStreams::Encode::Reader.stream(StringIO.new(with_byte_order_mark), encoding: "UTF-8", &:read)

          assert_equal "name,city", data
        end

        it "is removed when it is split across reads" do
          chunks = []
          IOStreams::Encode::Reader.stream(StringIO.new(with_byte_order_mark), encoding: "UTF-8") do |io|
            while (chunk = io.read(1))
              chunks << chunk
            end
          end

          assert_equal "name,city".chars, chunks
        end

        it "is kept when it is not at the start" do
          data = IOStreams::Encode::Reader.stream(StringIO.new("a\xEF\xBB\xBFb".b), encoding: "UTF-8", &:read)

          assert_equal "a\uFEFFb", data
        end

        it "is kept with encoding: BINARY" do
          data = IOStreams::Encode::Reader.stream(StringIO.new(with_byte_order_mark), encoding: "BINARY", &:read)

          assert_equal with_byte_order_mark, data
        end
      end

      describe "external:internal encoding" do
        let(:windows1252) { "caf\xE9\nna\xEFve\n".b }

        it "converts the data from the external encoding to the internal encoding, like File.read" do
          data = IOStreams::Encode::Reader.stream(StringIO.new(windows1252), encoding: "Windows-1252:UTF-8", &:read)

          assert_equal "caf\u00e9\nna\u00efve\n", data
          assert_equal Encoding::UTF_8, data.encoding
        end

        it "converts each block, keeping a character split across reads" do
          utf16 = "caf\u00e9".encode("UTF-16LE").b
          data  = +""
          IOStreams::Encode::Reader.stream(StringIO.new(utf16), encoding: "UTF-16LE:UTF-8") do |io|
            while (block = io.read(3))
              data << block
            end
          end

          assert_equal "caf\u00e9", data
        end

        it "converts a character longer than two bytes that is split across reads" do
          # The emoji is a surrogate pair, four bytes in UTF-16LE, so that a read can end after one, two or three of them.
          text  = "a\u{1F600}\u00e9"
          utf16 = text.encode("UTF-16LE").b
          [1, 2, 3].each do |size|
            data = +""
            IOStreams::Encode::Reader.stream(StringIO.new(utf16), encoding: "UTF-16LE:UTF-8") do |io|
              while (block = io.read(size))
                data << block
              end
            end

            assert_equal text, data, "Reading #{size} bytes at a time"
          end
        end

        it "reads lines in the internal encoding" do
          lines = []
          IOStreams.stream(StringIO.new(windows1252)).encoding("Windows-1252:UTF-8").each(:line) { |line| lines << line }

          assert_equal %w[café naïve], lines
          assert_equal [Encoding::UTF_8], lines.map(&:encoding).uniq
        end

        it "raises for a character that the internal encoding does not have" do
          assert_raises(Encoding::UndefinedConversionError) do
            IOStreams::Encode::Reader.stream(StringIO.new(windows1252), encoding: "Windows-1252:US-ASCII", &:read)
          end
        end

        it "replaces a character that the internal encoding does not have when replace is supplied" do
          data = IOStreams::Encode::Reader.stream(StringIO.new(windows1252), encoding: "Windows-1252:US-ASCII", replace: "?", &:read)

          assert_equal "caf?\nna?ve\n", data
        end

        it "raises ArgumentError for an unknown encoding" do
          assert_raises(ArgumentError) { IOStreams::Encode::Reader.stream(StringIO.new(windows1252), encoding: "Nope:UTF-8", &:read) }
        end
      end
    end

    # The stream that `#reader` supplies with an encoding reads like an IO that reads text in an encoding, such as
    # `File.open(name, "r:Windows-1252:UTF-8")`, so that code that reads lines from it, such as `CSV.new(io)`, works
    # whether or not an encoding is set, as it does with any other stream.
    describe "reading like an IO that converts text" do
      # Windows-1252 text of more than one block of the data that the encode stream reads at a time, in which every
      # character that is not ASCII is two bytes once it is converted to UTF-8.
      let(:windows1252) { Array.new(4000) { |i| "#{i},caf\xE9 na\xEFve\r\n".b }.join }

      # Returns what the block returns for a File that reads the data in the encoding, once it has checked that the
      # block returns the same, with the same encodings, for the stream that `#reader` supplies with the encoding.
      def read_like_io(data, encoding, &block)
        expected = Tempfile.create("encode_reader") do |file|
          file.binmode
          file.write(data)
          file.flush
          File.open(file.path, "rb:#{encoding}", &block)
        end

        assert_equal with_encodings(expected), with_encodings(IOStreams.stream(StringIO.new(data)).encoding(encoding).reader(&block))
        expected
      end

      # Returns [Object] the result, with each String in it as its value and its encoding, so that they compare by both.
      def with_encodings(result)
        case result
        when String
          [result, result.encoding]
        when Array
          result.map { |item| with_encodings(item) }
        else
          result
        end
      end

      it "reads lines in the internal encoding, like an IO that converts text" do
        results = read_like_io(windows1252, "Windows-1252:UTF-8") do |io|
          [
            io.gets, io.gets(chomp: true), io.gets(","), io.gets(4), io.readline, io.gets(nil, 5), io.each_line.count,
            io.gets, io.eof?
          ]
        end

        assert_equal ["0,caf\u00e9 na\u00efve\r\n", "1,caf\u00e9 na\u00efve", "2,", "caf\u00e9", " na\u00efve\r\n", "3,caf", 3997, nil, true],
                     results
        assert_equal Encoding::UTF_8, results.first.encoding
      end

      it "reads the rest of the lines like IO#readlines" do
        results = read_like_io(windows1252, "Windows-1252:UTF-8") { |io| [io.gets, io.readlines(chomp: true), io.readlines] }

        assert_equal Array.new(3999) { |i| "#{i + 1},caf\u00e9 na\u00efve" }, results[1]
        assert_empty results.last
      end

      it "reads lines of the text that it checks, like an IO that reads text in an encoding" do
        # Every line splits a character between the blocks that the encode stream reads, and between their halves.
        data    = "\u00e9\n#{'x' * 65_533}\u00e9\u00e9\n#{"\u00e9t\u00e9\n" * 3}".b
        results = read_like_io(data, "UTF-8") { |io| [io.gets(1), io.gets, io.gets(65_534), io.readlines, io.gets] }

        assert_equal ["\u00e9", "\n", "#{'x' * 65_533}\u00e9", ["\u00e9\n", *(["\u00e9t\u00e9\n"] * 3)], nil], results
      end

      it "reads lines in an encoding that is not ASCII compatible, like an IO that converts text" do
        results = read_like_io("ab\ncd\nef", "UTF-8:UTF-16LE") { |io| [io.gets, io.gets(1), io.gets(chomp: true), io.read] }

        assert_equal %W[ab\n c d ef].map { |line| line.encode("UTF-16LE") }, results
      end

      it "is read by CSV, as an IO that converts text is" do
        rows = IOStreams.stream(StringIO.new(windows1252)).encoding("Windows-1252:UTF-8").reader { |io| CSV.new(io).to_a }

        assert_equal 4000, rows.size
        assert_equal ["3999", "caf\u00e9 na\u00efve"], rows.last
      end

      it "reads upto the length in whole characters, and the first character when it is longer" do
        parts = IOStreams.stream(StringIO.new("\xE9\xE9ab\xE9c".b)).encoding("Windows-1252:UTF-8").reader do |io|
          [io.read(1), io.read(3), io.read(2), io.read(3), io.read(3)]
        end

        assert_equal ["\u00e9", "\u00e9a", "b", "\u00e9c", nil], parts
      end

      it "reads part of the text that has already been converted, in whole characters" do
        IOStreams.stream(StringIO.new("\xE9\xE9a".b)).encoding("Windows-1252:UTF-8").reader do |io|
          assert_equal "\u00e9", io.readpartial(3)
          assert_equal Encoding::UTF_8, io.readpartial(1).encoding
          assert_equal "a", io.readpartial(3)
          assert_raises(EOFError) { io.readpartial(3) }
        end
      end

      it "removes the byte order mark from the start of the first line" do
        line = IOStreams.stream(StringIO.new("\xEF\xBB\xBFname\nJack\n".b)).encoding("UTF-8").reader(&:gets)

        assert_equal "name\n", line
      end

      it "cleans the lines" do
        lines = IOStreams.stream(StringIO.new("a\abc\nd\xE9f\n".b)).encoding("UTF-8", cleaner: :printable, replace: "").reader(&:readlines)

        assert_equal %W[abc\n df\n], lines
      end

      it "returns the lines before data that is not valid, and raises for the line that holds it" do
        IOStreams.stream(StringIO.new("first\nsecond\nthi\xFFrd\nfourth\n".b)).encoding("UTF-8").reader do |io|
          assert_equal "first\n", io.gets
          assert_equal "second\n", io.gets
          error = assert_raises(IOStreams::Errors::InvalidEncoding) { io.gets }
          assert_equal 16, error.byte_offset
          assert_raises(IOStreams::Errors::InvalidEncoding) { io.gets }
        end
      end

      it "raises IOError once the file that it reads is closed, rather than read the text already converted" do
        Tempfile.create(%w[iostreams .csv]) do |file|
          file.write("name\nJack\n")
          file.close
          io = IOStreams.path(file.path).encoding("UTF-8").reader do |stream|
            assert_equal "name\n", stream.gets
            stream
          end

          assert_raises(IOError) { io.gets }
        end
      end
    end
  end
end
