require_relative 'test_helper'
require 'csv'

class TabularWriterTest < Minitest::Test
  describe IOStreams::Record::Writer do
    let :csv_file_name do
      File.join(File.dirname(__FILE__), 'files', 'test.csv')
    end

    let :raw_csv_data do
      File.read(csv_file_name)
    end

    let :csv_rows do
      CSV.read(csv_file_name)
    end

    let :inputs do
      rows   = csv_rows.dup
      header = rows.shift
      rows.collect { |row| header.zip(row).to_h }
    end

    let :temp_file do
      Tempfile.new('iostreams')
    end

    let :file_name do
      temp_file.path
    end

    after do
      temp_file.delete
    end

    describe '.open' do
      it 'file' do
        IOStreams::Record::Writer.open(file_name) do |io|
          inputs.each { |hash| io << hash }
        end
        result = File.read(file_name)
        assert_equal raw_csv_data, result
      end

      it 'stream' do
        io_string = StringIO.new
        IOStreams::Line::Writer.open(io_string) do |io|
          IOStreams::Record::Writer.open(io) do |stream|
            inputs.each { |row| stream << row }
          end
        end
        assert_equal raw_csv_data, io_string.string
      end
    end

  end
end
