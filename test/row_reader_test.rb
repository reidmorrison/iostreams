require_relative 'test_helper'

class RowReaderTest < Minitest::Test
  describe IOStreams::Row::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'test.csv')
    end

    let :expected do
      CSV.read(file_name)
    end

    describe '.open' do
      it 'file' do
        rows = []
        IOStreams::Row::Reader.open(file_name) do |io|
          io.each { |row| rows << row }
        end
        assert_equal expected, rows
      end

      it 'stream' do
        rows = []
        IOStreams.line_reader(file_name) do |file|
          IOStreams::Row::Reader.open(file) do |io|
            io.each { |row| rows << row }
          end
        end
        assert_equal expected, rows
      end
    end

  end
end
