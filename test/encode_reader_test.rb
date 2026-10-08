require_relative "test_helper"

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
          skip "Does not raise on JRuby" if defined?(JRuby)
          input = StringIO.new(bad_data)

          IOStreams::Encode::Reader.stream(input, encoding: "UTF-8") do |io|
            assert_raises ::Encoding::UndefinedConversionError do
              io.read.encoding
            end
          end
        end

        it "strips invalid characters" do
          input = StringIO.new(bad_data)
          data  =
            IOStreams::Encode::Reader.stream(input, encoding: "UTF-8", replace: "", &:read)

          assert_equal cleansed_data, data
        end
      end

      describe "printable" do
        it "strips non-printable characters" do
          input = StringIO.new(bad_data)
          data  =
            IOStreams::Encode::Reader.stream(input, encoding: "UTF-8", cleaner: :printable, replace: "", &:read)

          assert_equal stripped_data, data
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
          assert_raises ArgumentError do
            IOStreams::Encode::Reader.stream(input, cleaner: :unknown_rule, &:read)
          end
        end

        it "raises for a cleaner that is neither a Symbol nor a Proc, rather than ignoring it" do
          error = assert_raises(ArgumentError) do
            IOStreams::Encode::Reader.stream(StringIO.new("x"), cleaner: "printable", &:read)
          end

          assert_includes error.message, %(Invalid cleaner "printable")
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
            IOStreams.path(file.path).option(:encode, encoding: "UTF-8").each(:line) { |line| lines << line }

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
            IOStreams.path(file.path).option(:encode, encoding: "BINARY").each(:line) { |line| lines << line }

            assert_equal ["name", "Jos\xE9".b], lines
            assert_equal Encoding::BINARY, lines.last.encoding
          end
        end

        it "reads the whole of a gzip file the same as the same data in a plain file" do
          Dir.mktmpdir do |dir|
            IOStreams.path(dir, "data.txt").write(latin1)
            IOStreams.path(dir, "data.txt.gz").write(latin1)
            plain = IOStreams.path(dir, "data.txt").option(:encode, encoding: "Windows-1252").read
            gzip  = IOStreams.path(dir, "data.txt.gz").option(:encode, encoding: "Windows-1252").read

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

        it "reads lines in the internal encoding" do
          lines = []
          IOStreams.stream(StringIO.new(windows1252)).stream(:encode, encoding: "Windows-1252:UTF-8").each(:line) { |line| lines << line }

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
  end
end
