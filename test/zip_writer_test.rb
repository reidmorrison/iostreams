require_relative 'test_helper'
require 'zip'

# Unit Test for IOStreams::Zip
module Streams
  class ZipWriterTest < Minitest::Test
    context IOStreams::Zip::Writer do
      setup do
        file_name = File.join(File.dirname(__FILE__), 'files', 'text.txt')
        @data     = File.read(file_name)
      end

      context '.open' do
        should 'file' do
          temp_file = Tempfile.new('rocket_job')
          file_name = temp_file.to_path
          IOStreams::Zip::Writer.open(file_name, zip_file_name: 'text.txt') do |io|
            io.write(@data)
          end
          result = Zip::File.open(file_name) do |zip_file|
            zip_file.first.get_input_stream.read
          end
          temp_file.delete
          assert_equal @data, result
        end

        should 'stream' do
          io_string = StringIO.new(''.force_encoding('ASCII-8BIT'))
          IOStreams::Zip::Writer.open(io_string) do |io|
            io.write(@data)
          end
          io     = StringIO.new(io_string.string)
          result = nil
          begin
            zin    = ::Zip::InputStream.new(io)
            entry  = zin.get_next_entry
            result = zin.read
          ensure
            zin.close if zin
          end
          assert_equal @data, result
        end
      end

    end
  end
end
