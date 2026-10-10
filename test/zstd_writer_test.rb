require_relative "test_helper"

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
        assert_equal decompressed + decompressed, ZstdLibrary.decompress(File.binread(file_name))
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
        assert_equal decompressed + decompressed, ZstdLibrary.decompress(io_string.string)
      end
    end

    describe "#write" do
      it "returns the number of bytes written before compression" do
        IOStreams::Zstd::Writer.stream(StringIO.new("".b)) do |io|
          assert_equal 5, io.write("hello")
        end
      end

      it "does not end the frame when the block raises" do
        # Data that does not compress, so that some of the frame is written before the block raises.
        io_string = StringIO.new("".b)
        assert_raises(ArgumentError) do
          IOStreams::Zstd::Writer.stream(io_string) do |io|
            io.write(Random.new(1).bytes(1_000_000))
            raise ArgumentError, "failed"
          end
        end

        refute_predicate io_string, :closed?
        refute_empty io_string.string
        assert_raises(StandardError) { ZstdLibrary.decompress(io_string.string) }
      end

      it "compresses many small writes into one frame" do
        lines     = Array.new(10_000) { |i| "#{i},same text on every line\n" }
        io_string = StringIO.new("".b)
        IOStreams::Zstd::Writer.stream(io_string) { |io| lines.each { |line| io.write(line) } }

        assert_equal lines.join, ZstdLibrary.decompress(io_string.string)
        assert_operator io_string.string.bytesize, :<, lines.join.bytesize / 10
      end
    end

    describe "level" do
      # Returns [String] the data compressed at the supplied level, or the default level when it is nil.
      def compress(data, level: nil)
        io_string = StringIO.new("".b)
        IOStreams::Zstd::Writer.stream(io_string, level: level) { |io| io.write(data) }
        io_string.string
      end

      it "compresses at the supplied level" do
        data = Array.new(20_000) { |i| "line #{i % 997},#{(i * 7919) % 104_729}\n" }.join

        # The frame does not record the level, but compressing the same data the same way at another level writes other
        # bytes, since zstd is deterministic.
        assert_equal compress(data), compress(data)
        refute_equal compress(data), compress(data, level: 19)
        assert_equal data, ZstdLibrary.decompress(compress(data, level: 19))
      end
    end
  end
end
