require_relative 'test_helper'

class DelimitedWriterTest < Minitest::Test
  describe IOStreams::Line::Writer do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'text.txt')
    end

    let :raw do
      File.read(file_name)
    end

    let :lines do
      raw.lines.map(&:strip)
    end

    describe '#<<' do
      it 'file' do
        temp_file = Tempfile.new('rocket_job')
        file_name = temp_file.to_path
        IOStreams::Line::Writer.open(file_name) do |io|
          lines.each { |line| io << line }
        end
        result = File.read(file_name)
        assert_equal raw, result
      end

      it 'stream' do
        io_string = StringIO.new
        IOStreams::Line::Writer.open(io_string) do |io|
          lines.each { |line| io << line }
        end
        assert_equal raw, io_string.string
      end
    end

    describe '.write' do
      it 'returns byte count' do
        io_string = StringIO.new
        count     = 0
        IOStreams::Line::Writer.open(io_string) do |io|
          lines.each { |line| count += io.write(line) }
        end
        assert_equal raw, io_string.string
        assert_equal raw.size, count
      end
    end

  end
end
