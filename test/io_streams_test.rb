require_relative 'test_helper'

class IOStreamsTest < Minitest::Test
  describe IOStreams do
    let :source_file_name do
      File.join(__dir__, 'files', 'text.txt')
    end

    let :data do
      File.read(source_file_name)
    end

    let :temp_file do
      Tempfile.new('iostreams')
    end

    let :target_file_name do
      temp_file.path
    end

    after do
      temp_file.delete
    end

    describe '.copy' do
      it 'streams' do
        size   = IOStreams.reader(source_file_name) do |source_stream|
          IOStreams.writer(target_file_name) do |target_stream|
            IOStreams.copy(source_stream, target_stream)
          end
        end
        actual = File.read(target_file_name)

        assert_equal actual, data
        assert_equal actual.size, size
      end

      it 'IO stream' do
        size   = File.open(source_file_name) do |source_stream|
          IOStreams.writer(target_file_name) do |target_stream|
            IOStreams.copy(source_stream, target_stream)
          end
        end
        actual = File.read(target_file_name)

        assert_equal actual, data
        assert_equal actual.size, size
      end

      it 'files' do
        size   = IOStreams.copy(source_file_name, target_file_name)
        actual = File.read(target_file_name)

        assert_equal actual, data
        assert_equal actual.size, size
      end
    end

    describe '.streams_for_file_name' do
      it 'file only' do
        streams = IOStreams.streams_for_file_name('a.xyz')
        assert_equal [], streams
      end

      it 'single stream' do
        streams = IOStreams.streams_for_file_name('a.gz')
        assert_equal [:gz], streams
      end

      it 'multiple streams' do
        streams = IOStreams.streams_for_file_name('a.xlsx.gz')
        assert_equal [:xlsx, :gz], streams
      end

      it 'is case-insensitive' do
        streams = IOStreams.streams_for_file_name('a.GzIp')
        assert_equal [:gzip], streams
      end

      it 'multiple streams are case-insensitive' do
        streams = IOStreams.streams_for_file_name('a.XlsX.Gz')
        assert_equal [:xlsx, :gz], streams
      end
    end

    describe '.each_line' do
      it 'returns a line at a time' do
        lines = []
        IOStreams.each_line(source_file_name) { |line| lines << line }
        assert_equal data.lines.map(&:strip), lines
      end
    end

  end
end
