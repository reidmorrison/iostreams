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
      let :psv_deprecation do
        /format\(:psv\) is deprecated when the streams read the rows as :csv, such as those of a spreadsheet, since v3\.0 raises ArgumentError for it, set format\(:csv\) instead, or no format/
      end

      it "reports a deprecation warning when the rows are read in another format, which still reads them in it" do
        line = __LINE__ + 3
        rows = assert_deprecated(/xlsx_reader_test\.rb:#{line}: warning: IOStreams: #{psv_deprecation.source}/) do
          rows = []
          IOStreams.path(file_name).format(:psv).each(:array) { |row| rows << row }
          rows
        end

        assert_equal xlsx_contents.map { |row| [row.join(",")] }, rows
      end

      it "reports a deprecation warning when the records or lines are read in another format" do
        records = assert_deprecated(psv_deprecation) do
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
          rows   = assert_deprecated(psv_deprecation) do
            rows = []
            stream.each(:array) { |row| rows << row }
            rows
          end

          assert_equal xlsx_contents.map { |row| [row.join(",")] }, rows
        end
      end

      it "reports none for :csv, or no format" do
        rows, records = refute_deprecated do
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
          rows = assert_deprecated(/xlsx_reader_test\.rb:#{line}: warning: IOStreams: the format :psv that the file name names is deprecated when the streams read the rows as :csv, such as those of a spreadsheet, since v3\.0 reads them as :csv whatever the file name, set format\(:csv\) to read them so in both versions\n\z/) do
            rows = []
            IOStreams.path(name).each(:array) { |row| rows << row }
            rows
          end

          assert_equal xlsx_contents.map { |row| [row.join(",")] }, rows
        end
      end

      it "reports none for format(:csv) on a file name that names another format, which reads the rows as CSV" do
        Dir.mktmpdir do |dir|
          name = File.join(dir, "report.psv.xlsx")
          FileUtils.cp(file_name, name)
          rows = refute_deprecated do
            rows = []
            IOStreams.path(name).format(:csv).each(:array) { |row| rows << row }
            rows
          end

          assert_equal xlsx_contents, rows
        end
      end

      it "reports none for a file name that names CSV, or no format" do
        Dir.mktmpdir do |dir|
          name = File.join(dir, "report.csv.xlsx")
          FileUtils.cp(file_name, name)
          rows = refute_deprecated do
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
          line = __LINE__ + 3
          rows = assert_deprecated(/xlsx_reader_test\.rb:#{line}: warning: IOStreams: #{name}: is deprecated for each call, set format\(:csv\) on the path instead, since the streams read the rows as :csv, such as those of a spreadsheet\n\z/) do
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
  end
end
