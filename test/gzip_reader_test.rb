require_relative "test_helper"

class GzipReaderTest < Minitest::Test
  describe IOStreams::Gzip::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "text.txt.gz")
    end

    let :decompressed do
      Zlib::GzipReader.open(file_name, &:read)
    end

    describe ".open" do
      it "file" do
        result = IOStreams::Gzip::Reader.file(file_name, &:read)

        assert_equal decompressed, result
      end

      it "stream" do
        result = File.open(file_name) do |file|
          IOStreams::Gzip::Reader.stream(file, &:read)
        end

        assert_equal decompressed, result
      end
    end

    describe "a stream of several gzip members" do
      let :members do
        [Zlib.gzip("first member\n"), Zlib.gzip(""), Zlib.gzip("second member\n" * 10_000)].join
      end

      let :expected do
        "first member\n#{"second member\n" * 10_000}"
      end

      # A pipe cannot rewind, so the next member must be read from the data left over from the previous one.
      def read_from_pipe(data)
        reader, writer = IO.pipe
        thread         = Thread.new do
          writer.write(data)
          writer.close
        end
        result = yield(reader)
        thread.join
        result
      ensure
        reader&.close
      end

      it "reads every member" do
        result = IOStreams::Gzip::Reader.stream(StringIO.new(members), &:read)

        assert_equal expected, result
      end

      it "reads every member from a pipe in blocks" do
        result = read_from_pipe(members) do |pipe|
          IOStreams::Gzip::Reader.stream(pipe) do |io|
            data = +""
            while (block = io.read(1000))
              data << block
            end
            data
          end
        end

        assert_equal expected, result
      end

      it "ignores zero bytes after the last member" do
        result = IOStreams::Gzip::Reader.stream(StringIO.new("#{members}\0\0\0"), &:read)

        assert_equal expected, result
      end

      it "raises when the data after a member is not gzip" do
        assert_raises(Zlib::GzipFile::Error) do
          IOStreams::Gzip::Reader.stream(StringIO.new("#{members}trailing"), &:read)
        end
      end

      it "copies every member" do
        output = StringIO.new
        IOStreams::Gzip::Reader.stream(StringIO.new(members)) { |io| IO.copy_stream(io, output) }

        assert_equal expected, output.string
      end

      it "reads every line from a file" do
        Tempfile.create(%w[iostreams .txt.gz]) do |file|
          file.binmode
          file.write(members)
          file.close
          lines = []
          IOStreams.path(file.path).each(:line) { |line| lines << line }

          assert_equal expected.lines.map(&:chomp), lines
        end
      end

      it "reaches the end of the stream after the last member" do
        IOStreams::Gzip::Reader.stream(StringIO.new(members)) do |io|
          refute_predicate io, :eof?
          io.read

          assert_predicate io, :eof?
          assert_nil io.read(10)
        end
      end

      it "returns the same encodings as Zlib::GzipReader" do
        IOStreams::Gzip::Reader.stream(StringIO.new(members)) do |io|
          assert_equal Encoding::BINARY, io.read(5).encoding
          assert_equal Encoding.default_external, io.read.encoding
        end
      end
    end
  end
end
