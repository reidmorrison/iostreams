require_relative 'test_helper'

# Unit Test for IOStreams::Gzip
module Streams
  class GzipWriterTest < Minitest::Test
    describe IOStreams::Gzip::Writer do
      before do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt.gz')
        @data      = Zlib::GzipReader.open(@file_name) { |gz| gz.read }
      end

      describe '.open' do
        it 'file' do
          temp_file = Tempfile.new('rocket_job')
          file_name = temp_file.to_path
          IOStreams::Gzip::Writer.open(file_name) do |io|
            io.write(@data)
          end
          result = Zlib::GzipReader.open(file_name) { |gz| gz.read }
          temp_file.delete
          assert_equal @data, result
        end

        it 'stream' do
          io_string = StringIO.new(''.force_encoding('ASCII-8BIT'))
          IOStreams::Gzip::Writer.open(io_string) do |io|
            io.write(@data)
          end
          io   = StringIO.new(io_string.string)
          gz   = Zlib::GzipReader.new(io)
          data = gz.read
          gz.close
          assert_equal @data, data
        end
      end

    end
  end
end
