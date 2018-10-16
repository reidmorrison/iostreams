require_relative 'test_helper'
require 'csv'

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
          csv  = IOStreams::Xlsx::Reader.open(file_name, &:read)
          assert_equal xlsx_contents, CSV.parse(csv)
        end
      end

      describe 'with a file stream' do
        it 'returns the contents of the file' do
          csv = ''
          File.open(file_name, 'rb') do |file|
            csv = IOStreams::Xlsx::Reader.open(file, &:read)
          end

          assert_equal xlsx_contents, CSV.parse(csv)
        end
      end
    end
  end
end
