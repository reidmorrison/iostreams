require_relative 'test_helper'

# Unit Test for IOStreams::Gzip
module Streams
  class Bzip2ReaderTest < Minitest::Test
    describe IOStreams::Bzip2::Reader do
      before do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt.bz2')
        @gzip_data = File.open(@file_name, 'rb') { |f| f.read }
        @data      = File.read(File.join(File.dirname(__FILE__), 'files', 'text.txt'))
      end

      describe '.open' do
        it 'file' do
          result = IOStreams::Bzip2::Reader.open(@file_name) do |io|
            io.read
          end
          assert_equal @data, result
        end

        it 'stream' do
          result = File.open(@file_name) do |file|
            IOStreams::Bzip2::Reader.open(file) do |io|
              io.read
            end
          end
          assert_equal @data, result
        end
      end

    end
  end
end
