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
  end
end
