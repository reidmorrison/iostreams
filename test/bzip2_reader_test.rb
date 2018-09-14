require_relative 'test_helper'

class Bzip2ReaderTest < Minitest::Test
  describe IOStreams::Bzip2::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'text.txt.bz2')
    end

    let :decompressed do
      File.read(File.join(File.dirname(__FILE__), 'files', 'text.txt'))
    end

    describe '.open' do
      it 'file' do
        result = IOStreams::Bzip2::Reader.open(file_name) do |io|
          io.read
        end
        assert_equal decompressed, result
      end

      it 'stream' do
        result = File.open(file_name) do |file|
          IOStreams::Bzip2::Reader.open(file) do |io|
            io.read
          end
        end
        assert_equal decompressed, result
      end
    end

  end
end
