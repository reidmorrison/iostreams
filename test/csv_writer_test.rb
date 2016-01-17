require_relative 'test_helper'
require 'csv'

module Streams
  class CSVWriterTest < Minitest::Test
    describe IOStreams::CSV::Writer do
      before do
        @file_name    = File.join(File.dirname(__FILE__), 'files', 'test.csv')
        @data         = ::CSV.read(@file_name)
        @raw_csv_data = ::File.read(@file_name)
      end

      describe '.open' do
        it 'file' do
          temp_file = Tempfile.new('rocket_job')
          file_name = temp_file.to_path
          IOStreams::CSV::Writer.open(file_name) do |io|
            @data.each { |row| io << row }
          end
          result = File.read(file_name)
          assert_equal @raw_csv_data, result
        end

        it 'stream' do
          io_string = StringIO.new
          IOStreams::CSV::Writer.open(io_string) do |io|
            @data.each { |row| io << row }
          end
          assert_equal @raw_csv_data, io_string.string
        end
      end

    end
  end
end
