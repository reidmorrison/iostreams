require_relative 'test_helper'

# Unit Test for IOStreams::Bzip2
module Streams
  class Bzip2WriterTest < Minitest::Test
    describe IOStreams::Bzip2::Writer do
      before do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt.gz')
        @data      = File.read(File.join(File.dirname(__FILE__), 'files', 'text.txt'))
      end

      describe '.open' do
        it 'file' do
          temp_file = Tempfile.new('rocket_job')
          file_name = temp_file.to_path
          IOStreams::Bzip2::Writer.open(file_name) do |io|
            io.write(@data)
          end

          File.open(file_name, 'rb') do |file|
            io     = RBzip2.default_adapter::Decompressor.new(file)
            result = io.read
            temp_file.delete
            assert_equal @data, result
          end
        end

        it 'stream' do
          io_string = StringIO.new(''.force_encoding('ASCII-8BIT'))
          IOStreams::Bzip2::Writer.open(io_string) do |io|
            io.write(@data)
          end

          io     = StringIO.new(io_string.string)
          rbzip2 = RBzip2.default_adapter::Decompressor.new(io)
          data   = rbzip2.read
          assert_equal @data, data
        end
      end

    end
  end
end
