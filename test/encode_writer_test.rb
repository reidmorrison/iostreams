require_relative 'test_helper'

class EncodeWriterTest < Minitest::Test
  describe IOStreams::Encode::Writer do
    let :bad_data do
      [
        "New M\xE9xico,NE".b,
        'good line',
        "New M\xE9xico,\x07SF".b
      ].join("\n").encode('BINARY')
    end

    let :cleansed_data do
      bad_data.gsub("\xE9".b, '?')
    end

    let :stripped_data do
      cleansed_data.gsub("\x07", '')
    end

    describe '#<<' do
      it 'file' do
        temp_file = Tempfile.new('rocket_job')
        file_name = temp_file.to_path
        IOStreams::Encode::Writer.open(file_name, encoding: 'ASCII-8BIT') do |io|
          io << bad_data
        end
        result = File.read(file_name, mode: 'rb')
        assert_equal bad_data, result
      end

      it 'stream' do
        io = StringIO.new(''.b)
        IOStreams::Encode::Writer.open(io, encoding: 'ASCII-8BIT') do |encoded|
          encoded << bad_data
        end
        assert_equal 'ASCII-8BIT', io.string.encoding.to_s
        assert_equal bad_data, io.string
      end

      it 'stream as utf-8' do
        io = StringIO.new('')
        assert_raises Encoding::UndefinedConversionError do
          IOStreams::Encode::Writer.open(io, encoding: 'UTF-8') do |encoded|
            encoded << bad_data
          end
        end
      end

      it 'stream as utf-8 with replacement' do
        io = StringIO.new('')
        IOStreams::Encode::Writer.open(io, encoding: 'UTF-8', encode_replace: '?') do |encoded|
          encoded << bad_data
        end
        assert_equal 'UTF-8', io.string.encoding.to_s
        assert_equal cleansed_data, io.string
      end

      it 'stream as utf-8 with replacement and printable cleansing' do
        io = StringIO.new('')
        IOStreams::Encode::Writer.open(io, encoding: 'UTF-8', encode_replace: '?', encode_cleaner: :printable) do |encoded|
          encoded << bad_data
        end
        assert_equal 'UTF-8', io.string.encoding.to_s
        assert_equal stripped_data, io.string
      end
    end

    describe '.write' do
      it 'returns byte count' do
        io_string = StringIO.new(''.b)
        count     = 0
        IOStreams::Encode::Writer.open(io_string, encoding: 'ASCII-8BIT') do |io|
          count += io.write(bad_data)
        end
        assert_equal bad_data, io_string.string
        assert_equal bad_data.size, count
      end
    end

  end
end
