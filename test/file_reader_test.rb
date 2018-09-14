require_relative 'test_helper'

class FileReaderTest < Minitest::Test
  describe IOStreams::File::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'text.txt')
    end

    let :raw do
      File.read(file_name)
    end

    describe '.open' do
      it 'file' do
        result = IOStreams::File::Reader.open(file_name) do |io|
          io.read
        end
        assert_equal raw, result
      end

      it 'does not support streams' do
        assert_raises ArgumentError do
          File.open(file_name) do |file|
            IOStreams::File::Reader.open(file) do |io|
              io.read
            end
          end
        end
      end
    end

  end
end
