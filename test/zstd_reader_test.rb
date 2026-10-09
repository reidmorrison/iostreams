require_relative "test_helper"
require "zstd-ruby"

class ZstdReaderTest < Minitest::Test
  describe IOStreams::Zstd::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "text.txt.zst")
    end

    let :decompressed do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    describe ".file" do
      it "file" do
        result = IOStreams::Zstd::Reader.file(file_name, &:read)

        assert_equal decompressed, result
      end

      it "stream" do
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
        result = read_with(::Zstd.compress(data), &:read)

        assert_equal data, result
        assert_equal Encoding::BINARY, result.encoding
      end

      it "reads in blocks of the requested length, returning nil at the end" do
        blocks = []
        read_with(::Zstd.compress(data)) do |io|
          while (block = io.read(1000))
            blocks << block
          end
        end

        assert_equal data, blocks.join
        assert(blocks[0..-2].all? { |block| block.bytesize == 1000 })
      end

      it "reads into the supplied buffer" do
        buffer = +""
        read_with(::Zstd.compress(data)) do |io|
          assert_same buffer, io.read(10, buffer)
          assert_equal data[0, 10], buffer
          io.read

          assert_nil io.read(10, buffer)
          assert_empty buffer
        end
      end

      it "returns an empty string for a length of zero" do
        assert_equal "", read_with(::Zstd.compress(data)) { |io| io.read(0) }
      end

      it "returns the contents of every frame" do
        compressed = ::Zstd.compress("first\n") + ::Zstd.compress("second\n")

        assert_equal "first\nsecond\n", read_with(compressed, &:read)
      end

      it "reads an empty stream" do
        read_with(::Zstd.compress("")) do |io|
          assert_predicate io, :eof?
          assert_nil io.read(10)
          assert_equal "", io.read
        end
      end

      it "raises for data that is not zstd" do
        assert_raises(RuntimeError) { read_with("not zstd data", &:read) }
      end
    end

    describe "#readpartial" do
      it "raises EOFError at the end of the stream" do
        IOStreams::Zstd::Reader.stream(StringIO.new(::Zstd.compress("abc"))) do |io|
          assert_equal "abc", io.readpartial(10)
          assert_predicate io, :eof?
          assert_raises(EOFError) { io.readpartial(10) }
        end
      end
    end
  end
end
