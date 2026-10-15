# frozen_string_literal: true

require_relative "test_helper"

# A ChunkReader reads data that arrives one chunk at a time like an IO, so that every stream the application reads, such
# as a decompressor, an S3 object, an HTTP response or what gpg decrypts, reads the same way, whatever size its chunks.
class ChunkReaderTest < Minitest::Test
  # Supplies the data in chunks of one size.
  class Chunks
    include IOStreams::ChunkReader

    def initialize(data, size)
      @data   = data
      @size   = size
      @offset = 0
    end

    def closed?
      false
    end

    private

    def next_chunk
      return if @offset >= @data.bytesize

      chunk    = @data.byteslice(@offset, @size)
      @offset += @size
      chunk
    end
  end

  # Supplies text in chunks of whole characters, of one number of characters, as bytes, which are read as text in the
  # encoding that `#chunk_encoding` returns, whatever encoding the chunks are tagged with.
  class TextChunks
    include IOStreams::ChunkReader

    def initialize(text, size)
      @encoding = text.encoding
      @chunks   = text.chars.each_slice(size).map { |characters| characters.inject(:+).b }
    end

    def closed?
      false
    end

    private

    def chunk_encoding
      @encoding
    end

    def next_chunk
      @chunks.shift
    end
  end

  # Supplies the chunks of text, and then raises IOStreams::Errors::InvalidEncoding, as the encode stream does for the
  # data that follows its last valid character, each time that it is asked for the next chunk.
  class InvalidAfter
    include IOStreams::ChunkReader

    def initialize(*chunks)
      @chunks = chunks
    end

    def closed?
      false
    end

    private

    def chunk_encoding
      Encoding::UTF_8
    end

    def next_chunk
      @chunks.shift || raise(IOStreams::Errors::InvalidEncoding.new("\"\\xFF\" is not valid UTF-8", byte_offset: 7))
    end
  end

  describe IOStreams::ChunkReader do
    # Returns what the block returns for a File that holds the data, once it has checked that the block returns the same
    # for a ChunkReader that receives the data in chunks of every size, from one byte to all of it.
    def read_like_io(data, &block)
      expected = Tempfile.create("chunk_reader") do |file|
        file.binmode
        file.write(data)
        file.flush
        File.open(file.path, "rb", &block)
      end

      (1..[data.bytesize, 1].max).each do |size|
        assert_equal expected, block.call(Chunks.new(data, size)), "Chunks of #{size} bytes"
      end
      expected
    end

    # Returns [Object] what the block returns, or the class of the exception that it raises.
    def outcome
      yield
    rescue StandardError => e
      e.class
    end

    it "reads lines like IO#gets" do
      data    = "first\nsecond\nthird line\nfourth\n\n\n\nfifth paragraph\n\nlast"
      results = read_like_io(data) do |io|
        [
          io.gets, io.gets(chomp: true), io.gets("d"), io.gets(4), io.gets("\n", 3), io.gets(nil, 5), io.gets(""),
          io.gets("", chomp: true), io.gets(""), io.gets, io.eof?
        ]
      end

      assert_equal ["first\n", "second", "third", " lin", "e\n", "fourt", "h\n\n", "fifth paragraph", "last", nil, true],
                   results
    end

    it "finds a separator that is split across chunks like IO#gets" do
      results = read_like_io("one\r\ntwo\r\n\r\nthree") do |io|
        [io.gets("\r\n"), io.gets("\r\n", chomp: true), io.gets("\r\n"), io.gets("\r\n"), io.gets("\r\n")]
      end

      assert_equal ["one\r\n", "two", "\r\n", "three", nil], results
    end

    it "removes a carriage return before a newline with chomp like IO#gets" do
      results = read_like_io("one\r\ntwo\n\r\n") { |io| [io.gets(chomp: true), io.gets(chomp: true), io.gets(chomp: true)] }

      assert_equal ["one", "two", ""], results
    end

    it "reads with a limit of 0 or a negative limit like IO" do
      results = read_like_io("one\ntwo\n") do |io|
        [io.gets(0), io.gets(-1), io.gets("\n", -2), io.gets, io.gets(0), io.readline(0)]
      end

      assert_equal ["", "one\n", "two\n", nil, "", ""], results
    end

    # Like IO on MRI. JRuby's IO loops forever instead, so this is not compared with an IO.
    it "raises ArgumentError for a limit of 0 when it reads every line, which would never reach the end" do
      reader = Chunks.new("one\ntwo\n", 3)

      assert_raises(ArgumentError) { reader.each_line(0) { nil } }
      assert_raises(ArgumentError) { reader.each_line("\n", 0) { nil } }
      assert_raises(ArgumentError) { reader.readlines(0) }
      assert_equal "one\n", reader.gets
    end

    it "reads lines like IO#readline" do
      results = read_like_io("one\ntwo") do |io|
        [io.readline, io.readline(chomp: true), outcome { io.readline }, outcome { io.readline("o") }]
      end

      assert_equal ["one\n", "two", EOFError, EOFError], results
    end

    it "reads the rest of the lines like IO#readlines" do
      results = read_like_io("zero\none\ntwo\nthree") do |io|
        [io.gets, io.readlines(chomp: true), io.readlines]
      end

      assert_equal ["zero\n", %w[one two three], []], results
      assert_equal %W[a\nb a\nc], read_like_io("a\nba\nc") { |io| io.readlines("b") }
    end

    it "yields each line like IO#each_line" do
      results = read_like_io("\n\nfirst\n\n\n\nsecond\n\nthird\n") do |io|
        lines = []
        io.each_line("", chomp: true) { |line| lines << line }
        lines
      end

      assert_equal %W[first second third\n], results
    end

    it "reads lines like IO#gets for any data, separator, limit and chunk size" do
      random = Random.new(42)
      200.times do
        data      = Array.new(random.rand(0..12)) { ["a", "b", "\n", "\r", "\n\n", "x" * random.rand(1..5)].sample(random: random) }.join
        separator = [nil, "\n", "", "\r\n", "ab", "\n\n"].sample(random: random)
        # IO applies a limit to a separator of more than one byte in a way of its own, sometimes returning more.
        limit     = [nil, nil, random.rand(1..6)].sample(random: random) unless separator && separator.bytesize > 1
        chomp     = [true, false].sample(random: random)

        read_like_io(data) do |io|
          lines = []
          while (line = limit ? io.gets(separator, limit, chomp: chomp) : io.gets(separator, chomp: chomp))
            lines << line
          end
          lines
        end
      end
    end

    # Text, whose encoding `#chunk_encoding` returns, is read like an IO that reads text in an encoding, such as
    # `File.open(name, "r:UTF-8")`, whatever number of characters each chunk holds.
    describe "text" do
      # Returns what the block returns for a File that reads the text in its encoding, once it has checked that the
      # block returns the same, with the same encodings, for a ChunkReader that receives the text in chunks of every
      # number of characters, from one to all of them.
      def read_text_like_io(text, &block)
        expected = Tempfile.create("chunk_reader") do |file|
          file.binmode
          file.write(text.b)
          file.flush
          File.open(file.path, "rb:#{text.encoding}", &block)
        end

        each_chunk_size(text) do |io, size|
          assert_equal with_encodings(expected), with_encodings(block.call(io)), "Chunks of #{size} characters"
        end
        expected
      end

      # Returns what the block returns for a ChunkReader that receives the text in chunks of one character, once it has
      # checked that the block returns the same, with the same encodings, for chunks of every other number of them.
      def read_text(text, &block)
        expected = block.call(TextChunks.new(text, 1))

        each_chunk_size(text) do |io, size|
          assert_equal with_encodings(expected), with_encodings(block.call(io)), "Chunks of #{size} characters"
        end
        expected
      end

      # Yields a ChunkReader that receives the text in chunks of each number of characters, and the number.
      def each_chunk_size(text)
        (1..[text.length, 1].max).each { |size| yield(TextChunks.new(text, size), size) }
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

      it "reads lines in the encoding of the text, and a limit that would split a character to the end of it, like IO" do
        text    = "a\u00e9b\nJos\u00e9\n\u{1F600}x\n\nM\u00fcnchen\n\n\nlast \u00e9"
        results = read_text_like_io(text) do |io|
          [
            io.gets(2), io.gets, io.gets(4), io.gets(chomp: true), io.gets(2), io.gets(""), io.gets("\u00fc"),
            io.gets(nil, 3), io.gets(""), io.gets(nil), io.gets, io.eof?
          ]
        end

        assert_equal ["a\u00e9", "b\n", "Jos\u00e9", "", "\u{1F600}", "x\n\n", "M\u00fc", "nch", "en\n\n", "last \u00e9", nil, true],
                     results
        assert_equal [Encoding::UTF_8], results.grep(String).map(&:encoding).uniq
      end

      it "reads the rest of the lines like IO#readlines, IO#each_line and IO#readline" do
        text    = "\u00e9t\u00e9\nna\u00efve\ncaf\u00e9"
        results = read_text_like_io(text) do |io|
          [io.readline(chomp: true), io.each_line(2).to_a, io.readlines, outcome { io.readline }]
        end

        assert_equal ["\u00e9t\u00e9", %W[na \u00ef ve \n ca f\u00e9], [], EOFError], results
      end

      it "finds a separator only at the start of a character, like IO" do
        # The second byte of the Shift_JIS character U+30DD is the byte of "|", and "\r\n" follows a two byte character.
        text    = "\u30DD|b\n\u30DD|\u65E5\r\n\u672C\r\n".encode("Shift_JIS")
        results = read_text_like_io(text) { |io| [io.gets("|"), io.gets("|"), io.gets("\r\n"), io.gets("\r\n")] }

        assert_equal "\x83|".b, "\u30DD".encode("Shift_JIS").b
        assert_equal ["\u30DD|", "b\n\u30DD|", "\u65E5\r\n", "\u672C\r\n"].map { |line| line.encode("Shift_JIS") }, results
      end

      it "reads text in an encoding that is not ASCII compatible, like IO" do
        text    = "ab\ncd\nef".encode("UTF-16LE")
        results = read_text_like_io(text) { |io| [io.gets, io.gets(1), io.gets(chomp: true), io.gets, io.gets, io.eof?] }

        assert_equal %W[ab\n c d ef].map { |line| line.encode("UTF-16LE") } + [nil, true], results
      end

      # IO skips the blank lines of UTF-16 text a byte at a time, so it reads the paragraph after them from within a
      # character, which is not compared.
      it "reads paragraphs of text in an encoding that is not ASCII compatible" do
        results = read_text("d\n\n\nef\ngh\n\n\nij".encode("UTF-16LE")) { |io| [io.gets, io.gets(""), io.gets("")] }

        assert_equal %W[d\n ef\ngh\n\n ij].map { |line| line.encode("UTF-16LE") }, results
      end

      # IO removes only the "\n" of UTF-16 text, unlike the "\r\n" of text in an encoding that is ASCII compatible.
      it "removes a carriage return before a newline with chomp in an encoding that is not ASCII compatible" do
        results = read_text("ab\r\ncd\r\n".encode("UTF-16LE")) { |io| [io.gets(chomp: true), io.readlines(chomp: true)] }

        assert_equal ["ab".encode("UTF-16LE"), ["cd".encode("UTF-16LE")]], results
      end

      it "reads lines like IO#gets for any text, separator, limit and chunk size" do
        random = Random.new(42)
        200.times do
          text      = Array.new(random.rand(0..12)) { ["a", "\u00e9", "\n", "\r", "\n\n", "\u{1F600}", "x" * random.rand(1..5)].sample(random: random) }.join.encode("UTF-8")
          separator = [nil, "\n", "", "\r\n", "\u00e9", "\n\n"].sample(random: random)
          # IO applies a limit to a separator of more than one byte, such as the blank line that ends a paragraph, in a
          # way of its own when it reads text, sometimes returning more.
          limit     = [nil, nil, random.rand(1..6)].sample(random: random) if separator.nil? || separator.bytesize == 1
          chomp     = [true, false].sample(random: random)

          read_text_like_io(text) do |io|
            lines = []
            while (line = limit ? io.gets(separator, limit, chomp: chomp) : io.gets(separator, chomp: chomp))
              lines << line
            end
            lines
          end
        end
      end

      it "converts a separator of ASCII characters to the encoding of the text" do
        results = read_text("ab,cd\nef".encode("UTF-16LE")) { |io| [io.gets(","), io.gets("\n".b, chomp: true), io.gets] }

        assert_equal ["ab,", "cd", "ef"].map { |line| line.encode("UTF-16LE") }, results
      end

      it "raises ArgumentError for a separator in another encoding that is not ASCII, like IO" do
        separator = "\xE9".dup.force_encoding("Windows-1252")
        error     = assert_raises(ArgumentError) { TextChunks.new("caf\u00e9\n", 2).gets(separator) }

        assert_equal "Invalid separator \"\\xE9\" in Windows-1252: supply it in the encoding of the text that is read, UTF-8",
                     error.message
        assert_raises(ArgumentError) { File.open(__FILE__, "r:UTF-8") { |io| io.gets(separator) } }
        assert_raises(ArgumentError) { TextChunks.new("caf\u00e9\n", 2).gets("\xE9".b) }
      end

      it "reads upto the length in whole characters, and the first character when it is longer" do
        results = read_text("\u00e9\u00e9\u00e9ab\u{1F600}cd") do |io|
          [io.read(0), io.read(1), io.read(3), io.read(5), io.read(2), io.read(3), io.read, io.read(1), io.read]
        end

        assert_equal ["", "\u00e9", "\u00e9", "\u00e9ab", "\u{1F600}", "cd", "", nil, ""], results
        assert_equal [Encoding::UTF_8], results.compact.map(&:encoding).uniq
      end

      it "reads the rest of the text in its encoding" do
        text = "ab\u00e9\ncd".encode("UTF-16LE")

        assert_equal [text, Encoding::UTF_16LE], with_encodings(read_text(text, &:read))
      end

      it "replaces the buffer with the text" do
        buffer = +"data of an earlier read"
        io     = TextChunks.new("\u00e9t\u00e9", 2)

        assert_same buffer, io.read(3, buffer)
        assert_equal ["\u00e9t", Encoding::UTF_8], with_encodings(buffer)
        assert_equal "\u00e9", io.read(5, buffer)
        assert_nil io.read(1, buffer)
        assert_empty buffer
      end

      it "reads part of the text that has already been received in whole characters" do
        io = TextChunks.new("\u00e9\u00e9ab\u{1F600}", 3)

        assert_equal ["", "\u00e9", "\u00e9a", "b", "\u{1F600}"],
                     [io.readpartial(0), io.readpartial(1), io.readpartial(10), io.readpartial(3), io.readpartial(1)]
        assert_raises(EOFError) { io.readpartial(1) }
        assert_equal Encoding::UTF_8, TextChunks.new("ab", 2).readpartial(1).encoding
      end

      it "returns the text before data that is not valid from a read of a length, and raises on the next read" do
        io = InvalidAfter.new("abc\n", "def")

        assert_equal "abc\n", io.read(4)
        assert_equal "def", io.read(4)
        error = assert_raises(IOStreams::Errors::InvalidEncoding) { io.read(4) }
        assert_equal 7, error.byte_offset
        assert_raises(IOStreams::Errors::InvalidEncoding) { io.read(4) }
      end

      it "raises for a line that reaches data that is not valid, rather than return the start of it" do
        io = InvalidAfter.new("abc\nd", "ef")

        assert_equal "abc\n", io.gets
        assert_raises(IOStreams::Errors::InvalidEncoding) { io.gets }
        assert_raises(IOStreams::Errors::InvalidEncoding) { InvalidAfter.new("abc\n").read }

        io = InvalidAfter.new("ab")

        assert_equal "ab", io.readpartial(5)
        assert_raises(IOStreams::Errors::InvalidEncoding) { io.readpartial(5) }
      end
    end
  end
end
