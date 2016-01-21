require_relative 'test_helper'

module Streams
  describe IOStreams::Xlsx::Reader do
    before do
      @xlsx_contents = [
        ['first column', 'second column', 'third column'],
        ['data 1', 'data 2', 'more data']
      ]
    end

    describe '.open' do
      let(:file_name) { File.join(File.dirname(__FILE__), 'files', 'spreadsheet.xlsx') }

      describe 'with a file path' do
        before do
          @file = File.open(file_name)
        end

        it 'returns the contents of the file' do
          rows = []
          IOStreams::Xlsx::Reader.open(@file) do |spreadsheet|
            spreadsheet.each { |row| rows << row }
          end
          assert_equal(@xlsx_contents, rows)
        end
      end

      describe 'with a file stream' do

        it 'returns the contents of the file' do
          rows = []
          File.open(file_name) do |file|
            IOStreams::Xlsx::Reader.open(file) do |spreadsheet|
              spreadsheet.each { |row| rows << row }
            end
          end

          assert_equal(@xlsx_contents, rows)
        end
      end
    end

  end
end
