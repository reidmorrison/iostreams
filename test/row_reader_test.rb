require_relative "test_helper"

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
        count = IOStreams::Row::Reader.file(file_name) do |io|
          io.each { |row| rows << row }
        end

        assert_equal expected, rows
        assert_equal expected.size, count
      end

      it "stream" do
        rows  = []
        count = IOStreams::Line::Reader.file(file_name) do |file|
          IOStreams::Row::Reader.stream(file) do |io|
            io.each { |row| rows << row }
          end
        end

        assert_equal expected, rows
        assert_equal expected.size, count
      end
    end

    describe "allowed and required columns" do
      let(:csv) { "Name,Secret\nJack,x\n" }

      def read_rows(**args)
        rows = []
        IOStreams::Line::Reader.stream(StringIO.new(csv)) do |file|
          IOStreams::Row::Reader.stream(file, **args) { |io| io.each { |row| rows << row } }
        end
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
    end
  end
end
