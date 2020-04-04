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
  end
end
