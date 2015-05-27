require_relative '../test_helper'

# Unit Test for RocketJob::Streams::Gzip
module Streams
  class GzipWriterTest < Minitest::Test
    context RocketJob::Streams::GzipWriter do
      setup do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt.gz')
        @data = Zlib::GzipReader.open(@file_name) {|gz| gz.read }
      end

      context '.open' do
        should 'file' do
          temp_file = Tempfile.new('rocket_job')
          file_name = temp_file.to_path
          RocketJob::Streams::GzipWriter.open(file_name) do |io|
            io.write(@data)
          end
          result = Zlib::GzipReader.open(file_name) {|gz| gz.read }
          temp_file.delete
          assert_equal @data, result
        end
        should 'stream' do
          io_string = StringIO.new(''.force_encoding('ASCII-8BIT'))
          RocketJob::Streams::GzipWriter.open(io_string) do |io|
            io.write(@data)
          end
          io = StringIO.new(io_string.string)
          gz = Zlib::GzipReader.new(io)
          data = gz.read
          gz.close
          assert_equal @data, data
        end
      end

    end
  end
end