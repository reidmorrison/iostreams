require_relative 'test_helper'

# Unit Test for IOStreams::File
module Streams
  class DelimitedReaderTest < Minitest::Test
    describe IOStreams::File::Reader do
      before do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt')
        @data      = []
        File.open(@file_name, 'rt') do |file|
          while !file.eof?
            @data << file.readline.strip
          end
        end
      end

      describe '.open' do
        it 'each_line file' do
          lines = []
          IOStreams::Delimited::Reader.open(@file_name) do |io|
            io.each_line { |line| lines << line }
          end
          assert_equal @data, lines
        end

        it 'each_line stream' do
          lines = []
          File.open(@file_name) do |file|
            IOStreams::Delimited::Reader.open(file) do |io|
              io.each_line { |line| lines << line }
            end
          end
          assert_equal @data, lines
        end

        ["\r\n", "\n\r", "\n", "\r"].each do |delimiter|
          it "autodetect delimiter: #{delimiter.inspect}" do
            lines  = []
            stream = StringIO.new(@data.join(delimiter))
            IOStreams::Delimited::Reader.open(stream, buffer_size: 15) do |io|
              io.each_line { |line| lines << line }
            end
            assert_equal @data, lines
          end
        end

        ['@', 'BLAH'].each do |delimiter|
          it "read delimited #{delimiter.inspect}" do
            lines  = []
            stream = StringIO.new(@data.join(delimiter))
            IOStreams::Delimited::Reader.open(stream, buffer_size: 15, delimiter: delimiter) do |io|
              io.each_line { |line| lines << line }
            end
            assert_equal @data, lines
          end
        end

        it "read binary delimited" do
          delimiter = "\x01"
          lines     = []
          stream    = StringIO.new(@data.join(delimiter))
          IOStreams::Delimited::Reader.open(stream, buffer_size: 15, delimiter: delimiter, encoding: IOStreams::BINARY_ENCODING) do |io|
            io.each_line { |line| lines << line }
          end
          assert_equal @data, lines
        end
      end

    end
  end
end
