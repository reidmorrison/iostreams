require_relative 'test_helper'

class TabularReaderTest < Minitest::Test
  describe IOStreams::Tabular::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'test.csv')
    end

    let :csv_rows do
      CSV.read(file_name)
    end

    let :expected do
      rows   = csv_rows.dup
      header = rows.shift.map(&:strip)
      rows.collect { |row| header.zip(row).to_h }
    end

    describe '.open' do
      it 'file' do
        rows = []
        IOStreams::Tabular::Reader.open(file_name) do |io|
          io.each { |row| rows << row }
        end
        assert_equal expected, rows
      end

      it 'stream' do
        rows = []
        IOStreams.line_reader(file_name) do |file|
          IOStreams::Tabular::Reader.open(file) do |io|
            io.each { |row| rows << row }
          end
        end
        assert_equal expected, rows
      end
    end

  end
end
