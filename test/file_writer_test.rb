require_relative '../test_helper'

# Unit Test for RocketJob::Streams::File
module Streams
  class FileWriterTest < Minitest::Test
    context RocketJob::Streams::FileWriter do
      setup do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt')
        @data      = File.read(@file_name)
      end

      context '.open' do
        should 'file' do
          temp_file = Tempfile.new('rocket_job')
          file_name = temp_file.to_path
          RocketJob::Streams::FileWriter.open(file_name) do |io|
            io.write(@data)
          end
          result = File.read(file_name)
          assert_equal @data, result
        end
        should 'stream' do
          io_string = StringIO.new
          RocketJob::Streams::FileWriter.open(io_string) do |io|
            io.write(@data)
          end
          assert_equal @data, io_string.string
        end
      end

    end
  end
end