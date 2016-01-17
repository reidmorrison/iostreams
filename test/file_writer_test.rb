require_relative 'test_helper'

# Unit Test for IOStreams::File
module Streams
  class FileWriterTest < Minitest::Test
    describe IOStreams::File::Writer do
      before do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt')
        @data      = File.read(@file_name)
      end

      describe '.open' do
        it 'file' do
          temp_file = Tempfile.new('rocket_job')
          file_name = temp_file.to_path
          IOStreams::File::Writer.open(file_name) do |io|
            io.write(@data)
          end
          result = File.read(file_name)
          assert_equal @data, result
        end

        it 'stream' do
          io_string = StringIO.new
          IOStreams::File::Writer.open(io_string) do |io|
            io.write(@data)
          end
          assert_equal @data, io_string.string
        end
      end

    end
  end
end
