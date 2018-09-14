require_relative 'test_helper'

class Bzip2WriterTest < Minitest::Test
  describe IOStreams::Bzip2::Writer do
    let :temp_file do
      Tempfile.new('iostreams')
    end

    let :file_name do
      temp_file.path
    end

    let :decompressed do
      File.read(File.join(File.dirname(__FILE__), 'files', 'text.txt'))
    end

    after do
      temp_file.delete
    end

    describe '.open' do
      it 'file' do
        IOStreams::Bzip2::Writer.open(file_name) do |io|
          io.write(decompressed)
        end

        File.open(file_name, 'rb') do |file|
          io     = RBzip2.default_adapter::Decompressor.new(file)
          result = io.read
          temp_file.delete
          assert_equal decompressed, result
        end
      end

      it 'stream' do
        io_string = StringIO.new(''.b)
        IOStreams::Bzip2::Writer.open(io_string) do |io|
          io.write(decompressed)
        end

        io     = StringIO.new(io_string.string)
        rbzip2 = RBzip2.default_adapter::Decompressor.new(io)
        data   = rbzip2.read
        assert_equal decompressed, data
      end
    end

  end
end
