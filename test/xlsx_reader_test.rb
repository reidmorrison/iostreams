require_relative "test_helper"
require "csv"
require "fileutils"
require "tmpdir"

class XlsxReaderTest
  describe IOStreams::Xlsx::Reader do
    let :file_name do
      File.join(File.dirname(__FILE__), "files", "spreadsheet.xlsx")
    end

    let :xlsx_contents do
      [
        ["first column", "second column", "third column"],
        ["data 1", "data 2", "more data"]
      ]
    end

    describe ".file" do
      describe "with a file path" do
        it "returns the contents of the file" do
          csv = IOStreams::Xlsx::Reader.file(file_name, &:read)

          assert_equal xlsx_contents, CSV.parse(csv)
        end
      end

      describe "with a file stream" do
        it "returns the contents of the file" do
          csv = ""
          File.open(file_name, "rb") do |file|
            csv = IOStreams::Xlsx::Reader.stream(file, &:read)
          end

          assert_equal xlsx_contents, CSV.parse(csv)
        end
      end
    end

    describe "a format set on the path of a spreadsheet, whose rows are read as CSV" do
      let :cells_deprecation do
        /the rows and records of a spreadsheet read without a type for each column are deprecated/
      end

      let :psv_deprecation do
        /format\(:psv\) is deprecated when the streams read the rows as :csv, such as those of a spreadsheet, since v3\.0 raises ArgumentError for it, set format\(:csv\) instead, or no format/
      end

      it "reports a deprecation warning when the rows are read in another format, which still reads them in it" do
        line = __LINE__ + 3
        rows = assert_deprecated(/xlsx_reader_test\.rb:#{line}: warning: IOStreams: #{psv_deprecation.source}/, cells_deprecation) do
          rows = []
          IOStreams.path(file_name).format(:psv).each(:array) { |row| rows << row }
          rows
        end

        assert_equal xlsx_contents.map { |row| [row.join(",")] }, rows
      end

      it "reports a deprecation warning when the records or lines are read in another format" do
        records = assert_deprecated(psv_deprecation, cells_deprecation) do
          records = []
          IOStreams.path(file_name).format(:psv).each(:hash) { |record| records << record }
          records
        end
        lines = assert_deprecated(psv_deprecation) do
          lines = []
          IOStreams.path(file_name).format(:psv).each(:line) { |text| lines << text }
          lines
        end

        assert_equal [{"first_columnsecond_columnthird_column" => "data 1,data 2,more data"}], records
        assert_equal xlsx_contents.map { |row| row.join(",") }, lines
      end

      it "reports a deprecation warning for the stream of a spreadsheet that IOStreams.stream reads" do
        File.open(file_name, "rb") do |file|
          stream = IOStreams.stream(file).stream(:xlsx).encoding("UTF-8").format(:psv)
          rows   = assert_deprecated(psv_deprecation, cells_deprecation, /#encoding is deprecated when the rows and records of a spreadsheet are read/) do
            rows = []
            stream.each(:array) { |row| rows << row }
            rows
          end

          assert_equal xlsx_contents.map { |row| [row.join(",")] }, rows
        end
      end

      it "reports no format for :csv, or no format, only rows read without a type for each column" do
        rows, records = assert_deprecated(cells_deprecation) do
          rows    = []
          records = []
          IOStreams.path(file_name).format(:csv).each(:array) { |row| rows << row }
          IOStreams.path(file_name).each(:hash) { |record| records << record }
          [rows, records]
        end

        assert_equal xlsx_contents, rows
        assert_equal [{"first_column" => "data 1", "second_column" => "data 2", "third_column" => "more data"}], records
      end

      it "reports none when the data is read, or the spreadsheet is read as it is stored" do
        csv, data = refute_deprecated do
          [IOStreams.path(file_name).format(:psv).read, IOStreams.path(file_name).raw.format(:psv).read]
        end

        assert_equal xlsx_contents, CSV.parse(csv)
        assert_equal File.binread(file_name), data
      end

      it "reports a deprecation warning for a format that the file name names, which still reads the rows in it" do
        Dir.mktmpdir do |dir|
          name = File.join(dir, "report.psv.xlsx")
          FileUtils.cp(file_name, name)
          line = __LINE__ + 3
          rows = assert_deprecated(/xlsx_reader_test\.rb:#{line}: warning: IOStreams: the format :psv that the file name names is deprecated when the streams read the rows as :csv, such as those of a spreadsheet, since v3\.0 reads them as :csv whatever the file name, set format\(:csv\) to read them so in both versions\n\z/, cells_deprecation) do
            rows = []
            IOStreams.path(name).each(:array) { |row| rows << row }
            rows
          end

          assert_equal xlsx_contents.map { |row| [row.join(",")] }, rows
        end
      end

      it "reports no format for format(:csv) on a file name that names another format, which reads the rows as CSV" do
        Dir.mktmpdir do |dir|
          name = File.join(dir, "report.psv.xlsx")
          FileUtils.cp(file_name, name)
          rows = assert_deprecated(cells_deprecation) do
            rows = []
            IOStreams.path(name).format(:csv).each(:array) { |row| rows << row }
            rows
          end

          assert_equal xlsx_contents, rows
        end
      end

      it "reports no format for a file name that names CSV, or no format" do
        Dir.mktmpdir do |dir|
          name = File.join(dir, "report.csv.xlsx")
          FileUtils.cp(file_name, name)
          rows = assert_deprecated(cells_deprecation) do
            rows = []
            IOStreams.path(name).each(:array) { |row| rows << row }
            IOStreams.path(file_name).each(:array) { |row| rows << row }
            rows
          end

          assert_equal xlsx_contents + xlsx_contents, rows
        end
      end
    end

    describe "a format supplied to each call for a spreadsheet, whose rows are read as CSV" do
      # Each setting of a call that chooses the format, with a value that chooses PSV.
      {
        format:             :psv,
        file_name:          "report.psv",
        original_file_name: "report.psv",
        default_format:     :psv
      }.each_pair do |name, value|
        it "reports a deprecation warning for #{name}: that says to set format(:csv) on the path, which still applies" do
          line = __LINE__ + 4
          rows = assert_deprecated(/xlsx_reader_test\.rb:#{line}: warning: IOStreams: #{name}: is deprecated for each call, set format\(:csv\) on the path instead, since the streams read the rows as :csv, such as those of a spreadsheet\n\z/,
                                   /the rows and records of a spreadsheet read without a type for each column are deprecated/) do
            rows = []
            IOStreams.path(file_name).each(:array, name => value) { |row| rows << row }
            rows
          end

          assert_equal xlsx_contents.map { |row| [row.join(",")] }, rows
        end
      end

      it "looks for the format of the text that the streams read only while deprecation warnings are on" do
        asked       = 0
        text_format = lambda do
          asked += 1
          :csv
        end
        rows    = []
        enabled = Warning[:deprecated]
        begin
          Warning[:deprecated] = false
          IOStreams::Xlsx::Reader.stub(:text_format, text_format) do
            IOStreams.path(file_name).format(:psv).each(:array) { |row| rows << row }
            IOStreams.path(file_name).each(:array, default_format: :psv) { |row| rows << row }
          end
        ensure
          Warning[:deprecated] = enabled
        end

        assert_equal 0, asked
        assert_equal xlsx_contents.map { |row| [row.join(",")] } * 2, rows
      end
    end

    describe "delimiter: and #encoding for the rows and records of a spreadsheet, which v3.0 raises ArgumentError for" do
      # A type for each column, without which reading the rows of a spreadsheet is deprecated itself.
      let :typed do
        IOStreams.path(file_name).schema(
          fields: [
            {name: "first column", type: "string"},
            {name: "second column", type: "string"},
            {name: "third column", type: "string"}
          ]
        )
      end

      # Returns [Array] what the stream yields in the mode, with the options of the call.
      def read_all(stream, mode, **)
        rows = []
        stream.each(mode, **) { |row| rows << row }
        rows
      end

      it "reports delimiter:, which still applies" do
        rows = assert_deprecated(/delimiter: is deprecated for the rows and records of a spreadsheet, which are its cells rather than lines of text, since v3\.0 raises ArgumentError for it, so remove it; each\(:line\) still takes it/) do
          read_all(typed, :array, delimiter: "\n")
        end

        assert_equal xlsx_contents, rows
      end

      it "reports an encoding set with #encoding, which still applies" do
        records = assert_deprecated(/#encoding is deprecated when the rows and records of a spreadsheet are read, which are its cells rather than lines of text, since v3\.0 raises ArgumentError for it, so remove it, and give its columns a schema, with which v2\.2 reads the text of its cells as UTF-8; each\(:line\) still takes it/) do
          read_all(typed.encoding("UTF-8"), :hash)
        end

        assert_equal [{"first column" => "data 1", "second column" => "data 2", "third column" => "more data"}], records
      end

      it "reports neither for its lines, nor a delimiter: of nil" do
        refute_deprecated do
          assert_equal xlsx_contents.map(&:to_csv).map(&:chomp), read_all(IOStreams.path(file_name), :line, delimiter: "\n")
          assert_equal xlsx_contents.map(&:to_csv).map(&:chomp), read_all(IOStreams.path(file_name).encoding("UTF-8"), :line)
          assert_equal xlsx_contents, read_all(typed, :array, delimiter: nil)
        end
      end
    end
  end
end
