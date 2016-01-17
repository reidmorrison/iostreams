require_relative 'test_helper'

# Unit Test for IOStreams::File
module Streams
  class CSVReaderTest < Minitest::Test
    describe IOStreams::CSV::Reader do
      before do
        @file_name = File.join(File.dirname(__FILE__), 'files', 'test.csv')
        @data      = CSV.read(@file_name)
      end

      describe '.open' do
        it 'file' do
          rows = []
          IOStreams::CSV::Reader.open(@file_name) do |io|
            io.each { |row| rows << row }
          end
          assert_equal @data, rows
        end

        it 'stream' do
          rows = []
          File.open(@file_name) do |file|
            IOStreams::CSV::Reader.open(file) do |io|
              io.each { |row| rows << row }
            end
          end
          assert_equal @data, rows
        end
      end

    end
  end
end
