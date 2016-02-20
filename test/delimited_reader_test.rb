require_relative 'test_helper'

# Unit Test for IOStreams::File
module Streams
  class DelimitedReaderTest < Minitest::Test
    describe IOStreams::Delimited::Reader do
      before do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt')
        @data      = []
        File.open(@file_name, 'rt') do |file|
          while !file.eof?
            @data << file.readline.strip
          end
        end
      end

      describe '#initialize' do
        it 'does not strip invalid characters' do
          bad_lines = [
            "New M\xE9xico,NE",
            'good line',
            "New M\xE9xico,SF"
          ]
          input     = StringIO.new(bad_lines.join("\n"))
          lines     = []
          IOStreams::Delimited::Reader.open(input) do |io|
            assert_equal false, io.strip_non_printable
            assert_raises ArgumentError do
              io.each { |line| lines << line }
            end
          end
        end

        it 'strips invalid characters' do
          bad_lines   = [
            "New M\xE9xico,NE",
            'good line',
            "New M\xE9xico,SF"
          ]
          fixed_lines = bad_lines.collect { |line| line.force_encoding('BINARY').gsub(/[^[:print:]|\r|\n]/, '') }
          input       = StringIO.new(bad_lines.join("\n"))
          lines       = []
          IOStreams::Delimited::Reader.open(input, strip_non_printable: true) do |io|
            assert_equal true, io.strip_non_printable
            io.each { |line| lines << line }
          end
          assert_equal fixed_lines, lines
        end
      end

      describe '#each' do
        it 'each_line file' do
          lines = []
          IOStreams::Delimited::Reader.open(@file_name) do |io|
            io.each { |line| lines << line }
          end
          assert_equal @data, lines
        end

        it 'each_line stream' do
          lines = []
          File.open(@file_name) do |file|
            IOStreams::Delimited::Reader.open(file) do |io|
              io.each { |line| lines << line }
            end
          end
          assert_equal @data, lines
        end

        ["\r\n", "\n\r", "\n", "\r"].each do |delimiter|
          it "autodetect delimiter: #{delimiter.inspect}" do
            lines  = []
            stream = StringIO.new(@data.join(delimiter))
            IOStreams::Delimited::Reader.open(stream, buffer_size: 15) do |io|
              io.each { |line| lines << line }
            end
            assert_equal @data, lines
          end
        end

        ['@', 'BLAH'].each do |delimiter|
          it "reads delimited #{delimiter.inspect}" do
            lines  = []
            stream = StringIO.new(@data.join(delimiter))
            IOStreams::Delimited::Reader.open(stream, buffer_size: 15, delimiter: delimiter) do |io|
              io.each { |line| lines << line }
            end
            assert_equal @data, lines
          end
        end

        it 'reads binary delimited' do
          delimiter = "\x01"
          lines     = []
          stream    = StringIO.new(@data.join(delimiter))
          IOStreams::Delimited::Reader.open(stream, buffer_size: 15, delimiter: delimiter, encoding: IOStreams::BINARY_ENCODING) do |io|
            io.each { |line| lines << line }
          end
          assert_equal @data, lines
        end
      end

      describe '.read' do
        it 'reads without delimiter' do
          result = IOStreams::Delimited::Reader.open(@file_name) do |io|
            io.read
          end
          file   = File.read(@file_name)
          assert_equal file, result
        end
      end

    end
  end
end
