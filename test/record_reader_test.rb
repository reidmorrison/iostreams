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
      it "raises InvalidHeader for a header row of two columns that are the same key, which a record cannot hold" do
        ["a,a,b\n1,2,3\n", "First Name,first_name,b\n1,2,3\n"].each do |csv|
          source = -> { IOStreams.stream(StringIO.new(csv)).format(:csv) }
          error  = assert_raises(IOStreams::Errors::InvalidHeader) { source.call.each(:hash) { |_record| nil } }
          assert_match(/\AThe columns ".*" and ".*" are the same key/, error.message)
          assert_raises(IOStreams::Errors::InvalidHeader) do
            IOStreams.stream(StringIO.new).format(:json).copy_from(source.call, mode: :hash)
          end
          rows = []
          source.call.each(:array) { |row| rows << row }

          assert_equal %w[1 2 3], rows.last
        end
        # Rows keep both columns, apart from those written to a format of keyed records, such as JSON.
        output = StringIO.new
        IOStreams.stream(output).format(:csv).copy_from(IOStreams.stream(StringIO.new("a,a,b\n1,2,3\n")).format(:csv), mode: :array)

        assert_equal "a,a,b\n1,2,3\n", output.string
        assert_raises(IOStreams::Errors::InvalidHeader) do
          IOStreams.stream(StringIO.new).format(:json).copy_from(IOStreams.stream(StringIO.new("a,a,b\n1,2,3\n")).format(:csv),
                                                                 mode: :array)
        end
      end

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

      it "returns an Enumerator of the records from #each without a block" do
        csv     = "name,zip\nJack,12345\n\nJill,23456\n"
        records = IOStreams.stream(StringIO.new(csv)).reader(:hash) { |io| io.each.with_index.to_a }
        kept    = IOStreams.stream(StringIO.new(csv)).reader(:hash, skip_blanks: true) { |io| io.each.to_a }

        assert_equal [[{"name" => "Jack", "zip" => "12345"}, 0], [nil, 1], [{"name" => "Jill", "zip" => "23456"}, 2]], records
        assert_equal [{"name" => "Jack", "zip" => "12345"}, {"name" => "Jill", "zip" => "23456"}], kept
      end
    end

    describe "#inspect" do
      it "shows the class and the format of the records, rather than the objects that it reads them with" do
        assert_equal "#<IOStreams::Record::Reader format=:json>", IOStreams.path(json_file_name).reader(:hash, &:inspect)
      end
    end
  end
end
