require_relative 'test_helper'

# Unit Test for IOStreams::File
module Streams
  class DelimitedReaderTest < Minitest::Test
    context IOStreams::File::Reader do
      setup do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt')
        @data      = []
        File.open(@file_name, 'rt') do |file|
          while !file.eof?
            @data << file.readline.strip
          end
        end
      end

      context '.open' do
        should 'each_line file' do
          lines = []
          IOStreams::Delimited::Reader.open(@file_name) do |io|
            io.each_line { |line| lines << line }
          end
          assert_equal @data, lines
        end
        should 'each_line stream' do
          lines = []
          File.open(@file_name) do |file|
            IOStreams::Delimited::Reader.open(file) do |io|
              io.each_line { |line| lines << line }
            end
          end
          assert_equal @data, lines
        end
      end

    end
  end
end
