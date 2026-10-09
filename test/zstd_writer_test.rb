require_relative "test_helper"
require "zstd-ruby"

class ZstdWriterTest < Minitest::Test
  describe IOStreams::Zstd::Writer do
    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :file_name do
      temp_file.path
    end

    let :decompressed do
      File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    after do
      temp_file.delete
    end

    describe ".file" do
      it "file" do
        result =
          IOStreams::Zstd::Writer.file(file_name) do |io|
            io.write(decompressed)
            io.write(decompressed)
            53_534
          end

        assert_equal 53_534, result
        assert_equal decompressed + decompressed, ::Zstd.decompress(File.binread(file_name))
      end

      it "stream" do
        io_string = StringIO.new("".b)
        result    =
          IOStreams::Zstd::Writer.stream(io_string) do |io|
            io.write(decompressed)
            io << decompressed
            53_534
          end

        assert_equal 53_534, result
        assert_equal decompressed + decompressed, ::Zstd.decompress(io_string.string)
      end
    end

    describe "#write" do
      it "returns the number of bytes written before compression" do
        IOStreams::Zstd::Writer.stream(StringIO.new("".b)) do |io|
          assert_equal 5, io.write("hello")
        end
      end

      it "compresses many small writes into one frame" do
        lines     = Array.new(10_000) { |i| "#{i},same text on every line\n" }
        io_string = StringIO.new("".b)
        IOStreams::Zstd::Writer.stream(io_string) { |io| lines.each { |line| io.write(line) } }

        assert_equal lines.join, ::Zstd.decompress(io_string.string)
        assert_operator io_string.string.bytesize, :<, lines.join.bytesize / 10
      end
    end
  end
end
