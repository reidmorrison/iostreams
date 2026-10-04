require_relative "test_helper"
require "logger"

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

      it "is enforced by default" do
        assert_predicate IOStreams, :enforce_column_restrictions?
      end

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

      it "reads a supplied column from a json key that matches it once cleansed" do
        assert_equal [{"name" => "x", "admin" => true}], read(json, format: :json, columns: %w[name admin])
      end

      it "does not change json records when no columns are restricted" do
        assert_equal [{"Name" => "x", "admin" => true}], read(json, format: :json)
      end

      it "does not rename supplied columns when no columns are restricted" do
        assert_equal [{"First Name" => "x"}], read("x\n", columns: ["First Name"])
      end
    end

    describe "allowed_columns when enforce_column_restrictions is false" do
      def read(input, **args)
        records = []
        IOStreams::Record::Reader.stream(StringIO.new(input), **args) { |io| io.each { |record| records << record } }
        records
      end

      # Returns [Array] the records read, and the warnings logged.
      def read_with_warnings(input, **args)
        output   = StringIO.new
        original = IOStreams.logger
        IOStreams.logger = Logger.new(output, level: :warn)
        records = read(input, **args)
        [records, output.string.lines.grep(/enforce_column_restrictions/).size]
      ensure
        IOStreams.logger = original
      end

      let(:csv) { "Name,Admin\nx,true\n" }
      let(:json) { %({"Name":"x","admin":true}\n{"Name":"y","admin":false}\n) }

      before do
        IOStreams.enforce_column_restrictions = false
      end

      after do
        IOStreams.enforce_column_restrictions = true
      end

      it "only accepts true or false" do
        assert_raises ArgumentError do
          IOStreams.enforce_column_restrictions = "yes"
        end
      end

      it "skips unknown columns in a csv header row without warning" do
        assert_equal [[{"name" => "x"}], 0], read_with_warnings(csv, allowed_columns: ["name"])
      end

      it "does not apply them to json records, and warns once" do
        expected = [{"Name" => "x", "admin" => true}, {"Name" => "y", "admin" => false}]

        assert_equal [expected, 1], read_with_warnings(json, format: :json, allowed_columns: ["name"])
      end

      it "does not raise when a json record is missing a required column, and warns" do
        assert_equal 1, read_with_warnings(json, format: :json, required_columns: ["state"]).last
      end

      it "does not warn when they would not change json records" do
        input = %({"name":"x"}\n)

        assert_equal [[{"name" => "x"}], 0], read_with_warnings(input, format: :json, allowed_columns: ["name"])
      end

      it "does not apply them to supplied columns, and warns" do
        records, warnings = read_with_warnings("x,true\n", columns: %w[name admin], allowed_columns: ["name"])

        assert_equal [{"name" => "x", "admin" => "true"}], records
        assert_equal 1, warnings
      end

      it "does not raise for supplied columns when skip_unknown is false, and warns" do
        args = {columns: %w[name admin], allowed_columns: ["name"], skip_unknown: false}

        assert_equal 1, read_with_warnings("x,true\n", **args).last
      end

      it "does not apply them without cleansing the header, and warns" do
        records, warnings = read_with_warnings(csv, allowed_columns: ["Name"], cleanse_header: false)

        assert_equal [{"Name" => "x", "Admin" => "true"}], records
        assert_equal 1, warnings
      end

      it "does not warn when no columns are restricted" do
        assert_equal 0, read_with_warnings(json, format: :json).last
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
