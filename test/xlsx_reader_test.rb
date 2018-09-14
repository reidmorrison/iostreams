require_relative 'test_helper'

class XlsxReaderTest
  describe IOStreams::Xlsx::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'spreadsheet.xlsx')
    end

    let :xlsx_contents do
      [
        ['first column', 'second column', 'third column'],
        ['data 1', 'data 2', 'more data']
      ]
    end

    describe '.open' do
      describe 'with a file path' do
        it 'returns the contents of the file' do
          rows = []
          IOStreams::Xlsx::Reader.open(file_name) do |stream|
            stream.each { |row| rows << row }
          end
          assert_equal xlsx_contents, rows
        end
      end

      describe 'with a file stream' do
        it 'returns the contents of the file' do
          rows = []
          File.open(file_name) do |file|
            IOStreams::Xlsx::Reader.open(file) do |stream|
              stream.each { |row| rows << row }
            end
          end

          assert_equal xlsx_contents, rows
        end
      end
    end
  end
end
