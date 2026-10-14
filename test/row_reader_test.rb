# frozen_string_literal: true

require_relative "test_helper"
require "logger"

class RowReaderTest < Minitest::Test
  describe IOStreams::Row::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "test.csv")
    end

    let :expected do
      CSV.read(file_name)
    end

    describe "#each" do
      it "file" do
        rows  = []
        count = IOStreams.path(file_name).reader(:array) do |io|
          io.each { |row| rows << row }
        end

        assert_equal expected, rows
        assert_equal expected.size, count
      end

      it "stream" do
        rows  = []
        count = File.open(file_name) do |file|
          IOStreams.stream(file).reader(:array) do |io|
            io.each { |row| rows << row }
          end
        end

        assert_equal expected, rows
        assert_equal expected.size, count
      end

      it "keeps newlines within quoted values when reading a file" do
        embedded_file_name = File.join(File.dirname(__FILE__), "files", "embedded_lines_test.csv")
        rows               = []
        IOStreams.path(embedded_file_name).each(:array) { |row| rows << row }

        assert_equal CSV.read(embedded_file_name), rows
      end
    end

    describe "#collect" do
      it "is Enumerable, as a reader of records is" do
        csv = "name,zip\nJack,12345\nJill,23456\n"

        assert_equal %w[name Jack Jill], IOStreams.stream(StringIO.new(csv)).reader(:array) { |io| io.collect(&:first) }
        assert_equal [%w[name zip], %w[Jack 12345]], IOStreams.stream(StringIO.new(csv)).reader(:array) { |io| io.first(2) }
      end
    end

    describe "allowed and required columns" do
      allow_deprecation(/describe the columns of the file with #schema instead/)

      let(:csv) { "Name,Secret\nJack,x\n" }

      def read_rows(**args)
        rows = []
        IOStreams.stream(StringIO.new(csv)).each(:array, **args) { |row| rows << row }
        rows
      end

      it "applies required columns to the header row" do
        assert_raises(IOStreams::Errors::InvalidHeader) { read_rows(required_columns: ["missing"]) }
      end

      it "applies required columns to the header row when cleanse_header is false" do
        assert_raises(IOStreams::Errors::InvalidHeader) { read_rows(required_columns: ["missing"], cleanse_header: false) }
      end

      it "compares the header row as-is when cleanse_header is false" do
        rows = read_rows(required_columns: ["Name"], cleanse_header: false)

        assert_equal [%w[Name Secret], %w[Jack x]], rows
      end

      it "applies allowed columns to supplied columns" do
        assert_raises(IOStreams::Errors::InvalidHeader) do
          read_rows(columns: %w[name secret], allowed_columns: ["name"], skip_unknown: false)
        end
      end

      it "applies required columns to supplied columns" do
        assert_raises(IOStreams::Errors::InvalidHeader) do
          read_rows(columns: %w[name secret], required_columns: ["missing"])
        end
      end

      it "yields the header row as read" do
        rows = read_rows(allowed_columns: ["name"])

        assert_equal [%w[Name Secret], %w[Jack x]], rows
      end

      describe "when enforce_column_restrictions is false" do
        # Returns [Array] the rows read, and the warnings logged.
        def read_with_warnings(**args)
          output   = StringIO.new
          original = IOStreams.logger
          IOStreams.logger = Logger.new(output, level: :warn)
          rows = read_rows(**args)
          [rows, output.string.lines.grep(/enforce_column_restrictions/).size]
        ensure
          IOStreams.logger = original
        end

        before do
          IOStreams.enforce_column_restrictions = false
        end

        after do
          IOStreams.enforce_column_restrictions = true
        end

        it "still applies required columns to the header row by default" do
          assert_raises(IOStreams::Errors::InvalidHeader) { read_rows(required_columns: ["missing"]) }
        end

        it "warns instead of applying them with cleanse_header: false" do
          rows, warnings = read_with_warnings(required_columns: ["missing"], cleanse_header: false)

          assert_equal [%w[Name Secret], %w[Jack x]], rows
          assert_equal 1, warnings
        end

        it "warns instead of applying them to supplied columns" do
          rows, warnings = read_with_warnings(columns: %w[name secret], allowed_columns: ["name"], skip_unknown: false)

          assert_equal [%w[Name Secret], %w[Jack x]], rows
          assert_equal 1, warnings
        end

        it "does not warn when they would not change the columns" do
          _rows, warnings = read_with_warnings(columns: %w[name secret], allowed_columns: %w[name secret])

          assert_equal 0, warnings
        end
      end
    end
  end
end
