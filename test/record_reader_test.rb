require_relative 'test_helper'

class RecordReaderTest < Minitest::Test
  describe IOStreams::Record::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), 'files', 'test.csv')
    end

    let :json_file_name do
      File.join(File.dirname(__FILE__), 'files', 'test.json')
    end

    let :csv_rows do
      CSV.read(file_name)
    end

    let :expected do
      rows   = csv_rows.dup
      header = rows.shift
      rows.collect { |row| header.zip(row).to_h }
    end

    describe '#each' do
      it 'csv file' do
        records = []
        IOStreams::Record::Reader.open(file_name, cleanse_header: false) do |io|
          io.each { |row| records << row }
        end
        assert_equal expected, records
      end

      it 'json file' do
        records = []
        IOStreams::Record::Reader.open(json_file_name, cleanse_header: false) do |input|
          input.each { |row| records << row }
        end
        assert_equal expected, records
      end

      it 'stream' do
        rows = []
        IOStreams.line_reader(file_name) do |file|
          IOStreams::Record::Reader.open(file, cleanse_header: false) do |io|
            io.each { |row| rows << row }
          end
        end
        assert_equal expected, rows
      end
    end

    describe '#collect' do
      it 'json file' do
        records = IOStreams::Record::Reader.open(json_file_name) do |input|
          input.collect { |record| record["state"] }
        end
        assert_equal expected.collect { |record| record["state"] }, records
      end
    end

  end
end
