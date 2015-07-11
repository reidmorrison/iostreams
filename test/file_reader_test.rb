require_relative 'test_helper'

# Unit Test for IOStreams::File
module Streams
  class FileReaderTest < Minitest::Test
    context IOStreams::File::Reader do
      setup do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt')
        @data      = File.read(@file_name)
      end

      context '.open' do
        should 'file' do
          result = IOStreams::File::Reader.open(@file_name) do |io|
            io.read
          end
          assert_equal @data, result
        end
        should 'stream' do
          result = File.open(@file_name) do |file|
            IOStreams::File::Reader.open(file) do |io|
              io.read
            end
          end
          assert_equal @data, result
        end
      end

    end
  end
end