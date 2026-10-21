# frozen_string_literal: true

require_relative "test_helper"

class RecordReaderTest < Minitest::Test
  describe IOStreams::Record::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "test.csv")
    end

    let :json_file_name do
      File.join(File.dirname(__FILE__), "files", "test.json")
    end

    let :csv_rows do
      CSV.read(file_name)
    end

    let :expected do
      rows   = csv_rows.dup
      header = rows.shift
      rows.collect { |row| header.zip(row).to_h }
    end

    # The records of the CSV file, by the columns of its header row once cleansed, such as "address" for " address".
    let :cleansed do
      expected.map { |record| record.transform_keys(&:strip) }
    end

    describe "#each" do
      it "csv file" do
        records = []
        IOStreams.path(file_name).reader(:hash) do |io|
          io.each { |row| records << row }
        end

        assert_equal cleansed, records
      end

      it "json file, whose keys are kept as they are" do
        records = []
        IOStreams.path(json_file_name).format(:json).reader(:hash) do |input|
          input.each { |row| records << row }
        end

        assert_equal expected, records
      end

      it "stream" do
        rows = []
        File.open(file_name) do |file|
          IOStreams.stream(file).reader(:hash) do |io|
            io.each { |row| rows << row }
          end
        end

        assert_equal cleansed, rows
      end

      it "keeps newlines within quoted values when reading a file" do
        embedded_file_name = File.join(File.dirname(__FILE__), "files", "embedded_lines_test.csv")
        records            = []
        IOStreams.path(embedded_file_name).each(:hash) { |row| records << row }

        header, *rows = CSV.read(embedded_file_name)

        assert_equal rows.map { |row| header.map(&:strip).zip(row).to_h }, records
      end
    end

    describe "#collect" do
      it "json file" do
        records = IOStreams.path(json_file_name).reader(:hash) do |input|
          input.collect { |record| record["state"] }
        end

        assert_equal expected.collect { |record| record["state"] }, records
      end
    end

    describe "#inspect" do
      it "shows the class and the format of the records, rather than the objects that it reads them with" do
        assert_equal "#<IOStreams::Record::Reader format=:json>", IOStreams.path(json_file_name).reader(:hash, &:inspect)
      end
    end
  end
end
