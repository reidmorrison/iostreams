require_relative 'test_helper'

class LineReaderTest < Minitest::Test
  describe IOStreams::Line::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'text.txt')
    end

    let :data do
      data = []
      File.open(file_name, 'rt') do |file|
        while !file.eof?
          data << file.readline.strip
        end
      end
      data
    end

    describe '#each' do
      it 'each_line file' do
        lines = []
        count = IOStreams::Line::Reader.open(file_name) do |io|
          io.each { |line| lines << line }
        end
        assert_equal data, lines
        assert_equal data.size, count
      end

      it 'each_line stream' do
        lines = []
        count = File.open(file_name) do |file|
          IOStreams::Line::Reader.open(file) do |io|
            io.each { |line| lines << line }
          end
        end
        assert_equal data, lines
        assert_equal data.size, count
      end

      ["\r\n", "\n", "\r"].each do |delimiter|
        it "autodetect delimiter: #{delimiter.inspect}" do
          lines  = []
          stream = StringIO.new(data.join(delimiter))
          count = IOStreams::Line::Reader.open(stream, buffer_size: 15) do |io|
            io.each { |line| lines << line }
          end
          assert_equal data, lines
          assert_equal data.size, count
        end

        it "single read autodetect delimiter: #{delimiter.inspect}" do
          lines  = []
          stream = StringIO.new(data.join(delimiter))
          count = IOStreams::Line::Reader.open(stream) do |io|
            io.each { |line| lines << line }
          end
          assert_equal data, lines
          assert_equal data.size, count
        end
      end

      ['@', 'BLAH'].each do |delimiter|
        it "reads delimited #{delimiter.inspect}" do
          lines  = []
          stream = StringIO.new(data.join(delimiter))
          count = IOStreams::Line::Reader.open(stream, buffer_size: 15, delimiter: delimiter) do |io|
            io.each { |line| lines << line }
          end
          assert_equal data, lines
          assert_equal data.size, count
        end
      end

      it 'reads binary delimited' do
        delimiter = "\x01"
        lines     = []
        stream    = StringIO.new(data.join(delimiter).encode('ASCII-8BIT'))
        count = IOStreams::Line::Reader.open(stream, buffer_size: 15, delimiter: delimiter) do |io|
          io.each { |line| lines << line }
        end
        assert_equal data, lines
        assert_equal data.size, count
      end

      describe '#readline' do
        let(:short_line) { '0123456789' }
        let(:longer_line) { 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' }
        let(:delimiter) { "\r\n" }

        it 'reads delimiter in first block, no delimiter at end' do
          data        = [short_line, longer_line].join(delimiter)
          buffer_size = short_line.length + delimiter.size + (longer_line.size / 2)

          stream = StringIO.new(data)
          IOStreams::Line::Reader.open(stream, buffer_size: buffer_size) do |io|
            refute io.eof?
            assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }

            assert_equal short_line, io.readline
            assert_equal longer_line, io.readline

            assert io.eof?
            assert_nil io.readline
          end
        end

        it 'reads delimiter in second block, no delimiter at end' do
          data        = [longer_line, short_line, short_line].join(delimiter)
          buffer_size = (longer_line.length + delimiter.size + 5) / 2

          stream = StringIO.new(data)
          IOStreams::Line::Reader.open(stream, buffer_size: buffer_size) do |io|
            refute io.eof?
            assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
            assert_equal longer_line, io.readline
            assert_equal short_line, io.readline
            assert_equal short_line, io.readline
            assert io.eof?
            assert_nil io.readline
          end
        end

        it 'reads delimiter split across first and second blocks' do
          data        = [longer_line, short_line, short_line].join(delimiter)
          buffer_size = longer_line.length + 1

          stream = StringIO.new(data)
          IOStreams::Line::Reader.open(stream, buffer_size: buffer_size) do |io|
            refute io.eof?
            assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
            assert_equal longer_line, io.readline
            assert_equal short_line, io.readline
            assert_equal short_line, io.readline
            assert io.eof?
            assert_nil io.readline
          end
        end

        it 'reads file with no matching delimiter' do
          delimiter   = '@'
          data        = [longer_line, short_line, longer_line].join(delimiter) + delimiter
          buffer_size = longer_line.length + 1

          stream = StringIO.new(data)
          IOStreams::Line::Reader.open(stream, buffer_size: buffer_size) do |io|
            refute io.eof?
            assert_equal "\n", io.delimiter, -> { io.delimiter.ai }
            assert_equal data, io.readline
            assert io.eof?
            assert_nil io.readline
          end
        end

        it 'reads small file with no matching delimiter' do
          data        = short_line
          buffer_size = short_line.length + 100

          stream = StringIO.new(data)
          IOStreams::Line::Reader.open(stream, buffer_size: buffer_size) do |io|
            refute io.eof?
            assert_equal "\n", io.delimiter, -> { io.delimiter.ai }
            assert_equal short_line, io.readline
            assert io.eof?
            assert_nil io.readline
          end
        end

        it 'reads last line with the delimiter as the last character' do
          delimiter   = '@'
          data        = [longer_line, short_line, longer_line].join(delimiter) + delimiter
          buffer_size = longer_line.length + 1

          stream = StringIO.new(data)
          IOStreams::Line::Reader.open(stream, buffer_size: buffer_size, delimiter: delimiter) do |io|
            refute io.eof?
            assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
            assert_equal longer_line, io.readline
            assert_equal short_line, io.readline
            assert_equal longer_line, io.readline
            assert_nil io.readline
            assert io.eof?
          end
        end

        it 'reads last line with the multi-byte delimiter as the last bytes' do
          data        = [longer_line, short_line, longer_line].join(delimiter) + delimiter
          buffer_size = longer_line.length + 1

          stream = StringIO.new(data)
          IOStreams::Line::Reader.open(stream, buffer_size: buffer_size) do |io|
            refute io.eof?
            assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
            assert_equal longer_line, io.readline
            assert_equal short_line, io.readline
            assert_equal longer_line, io.readline
            assert_nil io.readline
            assert io.eof?
          end
        end

        describe 'read 1 char at a time' do
          let(:buffer_size) { 1 }

          it 'delimiter at the end' do
            data = [longer_line, short_line, longer_line].join(delimiter) + delimiter

            stream = StringIO.new(data)
            IOStreams::Line::Reader.open(stream, buffer_size: buffer_size) do |io|
              refute io.eof?
              assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
              assert_equal longer_line, io.readline
              assert_equal short_line, io.readline
              assert_equal longer_line, io.readline
              assert_nil io.readline
              assert io.eof?
            end
          end

          it 'no delimiter at the end' do
            data = [longer_line, short_line, longer_line].join(delimiter)

            stream = StringIO.new(data)
            IOStreams::Line::Reader.open(stream, buffer_size: buffer_size) do |io|
              refute io.eof?
              assert_equal delimiter, io.delimiter, -> { io.delimiter.ai }
              assert_equal longer_line, io.readline
              assert_equal short_line, io.readline
              assert_equal longer_line, io.readline
              assert_nil io.readline
              assert io.eof?
            end
          end
        end

        it 'reads empty file' do
          stream = StringIO.new
          IOStreams::Line::Reader.open(stream) do |io|
            assert io.eof?
          end
        end

        it 'prevents denial of service' do
          data   = 'a' * IOStreams::Line::Reader::MAX_BLOCKS_MULTIPLIER + 'a'
          stream = StringIO.new(data)
          assert_raises IOStreams::Errors::DelimiterNotFound do
            IOStreams::Line::Reader.open(stream, buffer_size: 1) do |io|
            end
          end

        end
      end
    end
  end
end
