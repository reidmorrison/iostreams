require_relative 'test_helper'

# Unit Test for IOStreams::Gzip
module Streams
  class GzipReaderTest < Minitest::Test
    context IOStreams::Gzip::Reader do
      setup do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt.gz')
        @gzip_data = File.open(@file_name, 'rb') { |f| f.read }
        @data      = Zlib::GzipReader.open(@file_name) { |gz| gz.read }
      end

      context '.open' do
        should 'file' do
          result = IOStreams::Gzip::Reader.open(@file_name) do |io|
            io.read
          end
          assert_equal @data, result
        end
        should 'stream' do
          result = File.open(@file_name) do |file|
            IOStreams::Gzip::Reader.open(file) do |io|
              io.read
            end
          end
          assert_equal @data, result
        end
      end

    end
  end
end
