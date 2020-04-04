require_relative "test_helper"
require "zip"

class ZipWriterTest < Minitest::Test
  describe IOStreams::Zip::Writer do
    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :file_name do
      temp_file.path
    end

    let :decompressed do
      ::File.read(File.join(File.dirname(__FILE__), "files", "text.txt"))
    end

    after do
      temp_file.delete
    end

    describe ".file" do
      it "file" do
        IOStreams::Zip::Writer.file(file_name, entry_file_name: "text.txt") do |io|
          io.write(decompressed)
        end
        result = IOStreams::Zip::Reader.file(file_name, &:read)
        assert_equal decompressed, result
      end

      it "stream" do
        io_string = StringIO.new("".b)
        IOStreams::Zip::Writer.stream(io_string) do |io|
          io.write(decompressed)
        end
        io = StringIO.new(io_string.string)
        result = IOStreams::Zip::Reader.stream(io, &:read)
        assert_equal decompressed, result
      end
    end
  end
end
