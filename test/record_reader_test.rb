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

    describe "#each" do
      it "csv file" do
        records = []
        IOStreams::Record::Reader.file(file_name, cleanse_header: false) do |io|
          io.each { |row| records << row }
        end

        assert_equal expected, records
      end

      it "json file" do
        records = []
        IOStreams::Record::Reader.file(json_file_name, cleanse_header: false, format: :json) do |input|
          input.each { |row| records << row }
        end

        assert_equal expected, records
      end

      it "stream" do
        rows = []
        IOStreams::Line::Reader.file(file_name) do |file|
          IOStreams::Record::Reader.stream(file, cleanse_header: false) do |io|
            io.each { |row| rows << row }
          end
        end

        assert_equal expected, rows
      end
    end

    describe "allowed_columns" do
      def read(input, **args)
        records = []
        IOStreams::Record::Reader.stream(StringIO.new(input), **args) { |io| io.each { |record| records << record } }
        records
      end

      let(:csv) { "Name,Admin\nx,true\n" }
      let(:json) { %({"Name":"x","admin":true}\n) }

      it "skips unknown columns in a csv header row" do
        assert_equal [{"name" => "x"}], read(csv, allowed_columns: ["name"])
      end

      it "skips unknown columns in a csv header row without cleansing the header" do
        assert_equal [{"Name" => "x"}], read(csv, allowed_columns: ["Name"], cleanse_header: false)
      end

      it "skips unknown columns when the columns are supplied" do
        assert_equal [{"name" => "x"}], read("x,true\n", columns: %w[name admin], allowed_columns: ["name"])
      end

      it "raises for unknown columns when the columns are supplied and skip_unknown is false" do
        assert_raises IOStreams::Errors::InvalidHeader do
          read("x,true\n", columns: %w[name admin], allowed_columns: ["name"], skip_unknown: false)
        end
      end

      it "skips unknown keys in json records" do
        assert_equal [{"name" => "x"}], read(json, format: :json, allowed_columns: ["name"])
      end

      it "skips unknown keys in json records when the columns are supplied" do
        assert_equal [{"name" => "x"}], read(%({"name":"x","admin":true}\n), format: :json, columns: %w[name admin], allowed_columns: ["name"])
      end

      it "compares json keys as-is without cleansing the header" do
        assert_equal [{"Name" => "x"}], read(json, format: :json, allowed_columns: ["Name"], cleanse_header: false)
      end

      it "raises for unknown keys in json records when skip_unknown is false" do
        error = assert_raises IOStreams::Errors::InvalidHeader do
          read(json, format: :json, allowed_columns: ["name"], skip_unknown: false)
        end
        assert_includes error.message, "admin"
      end

      it "raises when a json record is missing a required column" do
        error = assert_raises IOStreams::Errors::InvalidHeader do
          read(json, format: :json, required_columns: ["state"])
        end
        assert_includes error.message, "state"
      end

      it "does not change json records when no columns are restricted" do
        assert_equal [{"Name" => "x", "admin" => true}], read(json, format: :json)
      end

      it "does not rename supplied columns when no columns are restricted" do
        assert_equal [{"First Name" => "x"}], read("x\n", columns: ["First Name"])
      end
    end

    describe "#collect" do
      it "json file" do
        records = IOStreams::Record::Reader.file(json_file_name, format: :json) do |input|
          input.collect { |record| record["state"] }
        end

        assert_equal expected.collect { |record| record["state"] }, records
      end
    end
  end
end
