require_relative "test_helper"
require "csv"

class RowWriterTest < Minitest::Test
  describe IOStreams::Row::Writer do
    let :csv_file_name do
      File.join(File.dirname(__FILE__), "files", "test.csv")
    end

    let :raw_csv_data do
      File.read(csv_file_name)
    end

    let :csv_rows do
      CSV.read(csv_file_name)
    end

    let :temp_file do
      Tempfile.new("iostreams")
    end

    let :file_name do
      temp_file.path
    end

    after do
      temp_file.delete
    end

    describe "a header row whose columns are the same key" do
      # Returns [String] the rows written after the header row, with IOStreams::Stream#writer(:array), in the format.
      def write(format, header)
        out = StringIO.new
        IOStreams.stream(out).format(format).writer(:array) do |io|
          io << IOStreams::Row::HeaderRow.new(header)
          io << [1, 2, 3]
        end
        out.string
      end

      it "reports a deprecation warning for a format whose rows are records, and still writes the value of the last column, as before" do
        warning = /rows written to a format whose rows are records, such as JSON, under a header row whose columns are the same key, "a", are deprecated/

        assert_equal %({"a":2,"b":3}\n), assert_deprecated(warning) { write(:json, %w[a a b]) }
      end

      it "reports none for a format whose rows are Arrays, which writes every column, or for columns of their own keys" do
        assert_equal "a,a,b\n1,2,3\n", write(:csv, %w[a a b])
        assert_equal %({"a":1,"b":2,"c":3}\n), write(:json, %w[a b c])
      end
    end

    describe ".stream" do
      it "file" do
        result =
          IOStreams::Row::Writer.file(file_name) do |io|
            csv_rows.each { |array| io << array }
            53_534
          end

        assert_equal 53_534, result
        result = ::File.read(file_name)

        assert_equal raw_csv_data, result
      end

      it "streams" do
        io_string = StringIO.new
        result    =
          IOStreams::Line::Writer.stream(io_string) do |io|
            IOStreams::Row::Writer.stream(io) do |stream|
              csv_rows.each { |array| stream << array }
              53_534
            end
          end

        assert_equal 53_534, result
        assert_equal raw_csv_data, io_string.string
      end
    end
  end
end
