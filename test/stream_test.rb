require_relative 'test_helper'

class StreamTest < Minitest::Test
  describe IOStreams::Stream do
    let :source_file_name do
      File.join(__dir__, 'files', 'text.txt')
    end

    let :data do
      File.read(source_file_name)
    end

    let :bad_data do
      [
        "New M\xE9xico,NE".b,
        'good line',
        "New M\xE9xico,\x07SF".b
      ].join("\n").encode('BINARY')
    end

    let :stripped_data do
      bad_data.gsub("\xE9".b, '').gsub("\x07", '')
    end

    let :multiple_zip_file_name do
      File.join(File.dirname(__FILE__), 'files', 'multiple_files.zip')
    end

    let :zip_gz_file_name do
      File.join(File.dirname(__FILE__), 'files', 'text.zip.gz')
    end

    let :contents_test_txt do
      File.read(File.join(File.dirname(__FILE__), 'files', 'text.txt'))
    end

    let :contents_test_json do
      File.read(File.join(File.dirname(__FILE__), 'files', 'test.json'))
    end

    let(:string_io) { StringIO.new(data) }
    let(:stream) { IOStreams::Stream.new(string_io) }

    describe '.reader' do
      it 'reads a zip file' do
        File.open(multiple_zip_file_name, 'rb') do |io|
          result = IOStreams::Stream.new(io).
            file_name(multiple_zip_file_name).
            option(:zip, entry_file_name: 'test.json').
            reader { |io| io.read }
          assert_equal contents_test_json, result
        end
      end

      it 'reads a zip file from within a gz file' do
        File.open(zip_gz_file_name, 'rb') do |io|
          result = IOStreams::Stream.new(io).
            file_name(zip_gz_file_name).
            reader { |io| io.read }
          assert_equal contents_test_txt, result
        end
      end
    end

    describe '.line_reader' do
    end

    describe '.row_reader' do
    end

    describe '.record_reader' do
    end

    describe '.each_line' do
      it 'returns a line at a time' do
        lines = []
        stream.stream(:none)
        count = stream.each_line { |line| lines << line }
        assert_equal data.lines.map(&:strip), lines
        assert_equal data.lines.count, count
      end

      it 'strips non-printable characters' do
        input  = StringIO.new(bad_data)
        lines  = []
        stream = IOStreams::Stream.new(input)
        stream.stream(:encode, encoding: 'UTF-8', cleaner: :printable, replace: '')
        count = stream.each_line { |line| lines << line }
        assert_equal stripped_data.lines.map(&:strip), lines
        assert_equal stripped_data.lines.count, count
      end
    end

    describe '.each_row' do
    end

    describe '.each_record' do
    end

    describe '.writer' do
    end

    describe '.writer' do
    end

    describe '.line_writer' do
    end

    describe '.row_writer' do
    end

    describe '.record_writer' do
    end

  end
end
