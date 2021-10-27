require_relative "test_helper"

class Bzip2WriterTest < Minitest::Test
  describe IOStreams::Bzip2::Writer do
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
          IOStreams::Bzip2::Writer.file(file_name) do |io|
            io.write(decompressed)
            io.write(decompressed)
            53534
          end
        assert_equal 53534, result

        File.open(file_name, "rb") do |file|
          io     = ::Bzip2::FFI::Reader.new(file)
          result = io.read
          temp_file.delete
          assert_equal decompressed + decompressed, result
        end
      end

      it "stream" do
        io_string = StringIO.new("".b)
        result    =
          IOStreams::Bzip2::Writer.stream(io_string) do |io|
            io.write(decompressed)
            io.write(decompressed)
            53534
          end
        assert_equal 53534, result

        io     = StringIO.new(io_string.string)
        rbzip2 = ::Bzip2::FFI::Reader.new(io)
        data   = rbzip2.read
        assert_equal decompressed + decompressed, data
      end
    end
  end
end
