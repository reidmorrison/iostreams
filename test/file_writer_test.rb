require_relative 'test_helper'

class FileWriterTest < Minitest::Test
  describe IOStreams::File::Writer do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'text.txt')
    end

    let :raw do
      File.read(file_name)
    end

    describe '.open' do
      it 'file' do
        temp_file = Tempfile.new('rocket_job')
        file_name = temp_file.to_path
        IOStreams::File::Writer.open(file_name) do |io|
          io.write(raw)
        end
        result = File.read(file_name)
        assert_equal raw, result
      end

      it 'does not support streams' do
        io_string = StringIO.new
        assert_raises ArgumentError do
          IOStreams::File::Writer.open(io_string) do |io|
            io.write(raw)
          end
        end
      end
    end

  end
end
