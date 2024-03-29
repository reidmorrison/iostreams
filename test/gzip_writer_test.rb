require_relative "test_helper"

class GzipWriterTest < Minitest::Test
  describe IOStreams::Gzip::Writer do
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
          IOStreams::Gzip::Writer.file(file_name) do |io|
            io.write(decompressed)
            53534
          end
        assert_equal 53534, result

        result = Zlib::GzipReader.open(file_name, &:read)
        temp_file.delete
        assert_equal decompressed, result
      end

      it "stream" do
        io_string = StringIO.new("".b)
        result    =
          IOStreams::Gzip::Writer.stream(io_string) do |io|
            io.write(decompressed)
            53534
          end
        assert_equal 53534, result

        io   = StringIO.new(io_string.string)
        gz   = Zlib::GzipReader.new(io)
        data = gz.read
        gz.close
        assert_equal decompressed, data
      end
    end
  end
end
