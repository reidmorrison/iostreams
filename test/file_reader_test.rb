require_relative '../test_helper'

# Unit Test for RocketJob::Streams::File
module Streams
  class FileReaderTest < Minitest::Test
    context RocketJob::Streams::FileReader do
      setup do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt')
        @data      = File.read(@file_name)
      end

      context '.open' do
        should 'file' do
          result = RocketJob::Streams::FileReader.open(@file_name) do |io|
            io.read
          end
          assert_equal @data, result
        end
        should 'stream' do
          result = File.open(@file_name) do |file|
            RocketJob::Streams::FileReader.open(file) do |io|
              io.read
            end
          end
          assert_equal @data, result
        end
      end

    end
  end
end