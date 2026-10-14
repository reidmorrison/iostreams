# frozen_string_literal: true

require_relative "test_helper"

class ZstdReaderTest < Minitest::Test
  describe IOStreams::Zstd::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "text.txt.zst")
    end

    let :decompressed do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    describe ".file" do
      it "decompresses the file of the supplied name" do
        result = IOStreams::Zstd::Reader.file(file_name, &:read)

        assert_equal decompressed, result
      end
    end

    describe ".stream" do
      it "decompresses the supplied stream" do
        result = File.open(file_name) do |file|
          IOStreams::Zstd::Reader.stream(file, &:read)
        end

        assert_equal decompressed, result
      end
    end

    describe "#read" do
      let :data do
        Array.new(20_000) { |i| "#{i},#{'x' * (i % 50)}\n" }.join
      end

      def read_with(compressed, &)
        IOStreams::Zstd::Reader.stream(StringIO.new(compressed), &)
      end

      it "returns the rest of the stream as bytes" do
        result = read_with(ZstdLibrary.compress(data), &:read)

        assert_equal data, result
        assert_equal Encoding::BINARY, result.encoding
      end

      it "reads in blocks of the requested length, returning nil at the end" do
        blocks = []
        read_with(ZstdLibrary.compress(data)) do |io|
          while (block = io.read(1000))
            blocks << block
          end
        end

        assert_equal data, blocks.join
        assert(blocks[0..-2].all? { |block| block.bytesize == 1000 })
      end

      it "reads into the supplied buffer" do
        buffer = +""
        read_with(ZstdLibrary.compress(data)) do |io|
          assert_same buffer, io.read(10, buffer)
          assert_equal data[0, 10], buffer
          io.read

          assert_nil io.read(10, buffer)
          assert_empty buffer
        end
      end

      it "returns an empty string for a length of zero" do
        assert_equal "", read_with(ZstdLibrary.compress(data)) { |io| io.read(0) }
      end

      it "returns the contents of every frame" do
        compressed = ZstdLibrary.compress("first\n") + ZstdLibrary.compress("second\n")

        assert_equal "first\nsecond\n", read_with(compressed, &:read)
      end

      it "reads an empty stream" do
        read_with(ZstdLibrary.compress("")) do |io|
          assert_predicate io, :eof?
          assert_nil io.read(10)
          assert_equal "", io.read
        end
      end

      it "raises for data that is not zstd" do
        assert_raises(RuntimeError) { read_with("not zstd data", &:read) }
      end

      it "raises for empty data, which is not zstd, like the zstd command" do
        error = assert_raises(RuntimeError) { read_with("".b, &:read) }
        assert_equal "zstd decompress error: the data is empty", error.message
      end

      it "raises for a frame cut short at the end of the stream on JRuby, and returns the data before it on MRI" do
        compressed = ZstdLibrary.compress(data)
        cut_short  = compressed[0, compressed.bytesize - 3]

        if defined?(JRuby)
          error = assert_raises(RuntimeError) { read_with(cut_short, &:read) }
          assert_equal "zstd decompress error: Truncated source", error.message
        else
          # zstd-ruby does not report a frame cut short.
          result = read_with(cut_short, &:read)

          assert_operator result.bytesize, :<, data.bytesize
          assert data.start_with?(result)
        end
      end

      it "raises for data that does not match the checksum of its frame" do
        # Written by the zstd command, which ends each frame with the checksum of its content.
        corrupt = File.binread(file_name)
        corrupt.setbyte(15, corrupt.getbyte(15) ^ 0x01)

        error = assert_raises(RuntimeError) { read_with(corrupt, &:read) }
        assert_match(/Restored data doesn't match checksum/, error.message)
      end
    end

    describe "the decoder" do
      it "returns at most one block of zstd at a time, however well the data compresses" do
        data       = "\0" * 8_000_000
        decoder    = IOStreams::Zstd.library.decoder(StringIO.new(ZstdLibrary.compress(data)))
        block_size = 0
        size       = 0
        while (block = decoder.read_block)
          block_size = [block_size, block.bytesize].max
          size      += block.bytesize
        end

        assert_operator block_size, :<=, 128 * 1024
        assert_equal data.bytesize, size
      ensure
        decoder&.close
      end
    end

    describe "#readpartial" do
      it "raises EOFError at the end of the stream" do
        IOStreams::Zstd::Reader.stream(StringIO.new(ZstdLibrary.compress("abc"))) do |io|
          assert_equal "abc", io.readpartial(10)
          assert_predicate io, :eof?
          assert_raises(EOFError) { io.readpartial(10) }
        end
      end
    end
  end

  describe "on JRuby without the zstd-jni jar" do
    it "raises LoadError explaining how to add it" do
      skip "Only on JRuby" unless defined?(JRuby)

      # A separate process, since the tests have already added the jar to the classpath.
      script = <<~RUBY
        require "iostreams"
        begin
          IOStreams.stream(StringIO.new("")).stream(:zst).read
        rescue LoadError => e
          print e.message
        end
      RUBY
      lib     = File.expand_path("../lib", __dir__)
      message = IO.popen([RbConfig.ruby, "-I", lib, "-e", script], err: File::NULL, &:read)

      assert_match(/\APlease add the zstd-jni jar to the classpath to support Zstandard on JRuby/, message)
    end
  end
end
