require_relative "test_helper"
require "bigdecimal"
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

    describe "the number cells of a spreadsheet read with a schema" do
      # A workbook whose numbers are cells of type "n", as LibreOffice and many libraries write them, which creek reads
      # as Floats, such as `1001.0`.
      let :cells do
        File.join(File.dirname(__FILE__), "upgrade", "files", "cells.xlsx")
      end

      # A workbook of a cell of each kind, in the column "value", named in the column "name".
      let :number_cells do
        File.join(File.dirname(__FILE__), "files", "number_cells.xlsx")
      end

      let :strings do
        {fields: %w[id amount zip ok note].map { |name| {name: name, type: "string"} }}
      end

      let :values do
        {fields: [{name: "name", type: "string"}, {name: "value", type: "string"}]}
      end

      # Returns [Array] what the path yields in the mode.
      def read_all(path, mode)
        rows = []
        path.each(mode) { |row| rows << row }
        rows
      end

      # Returns [Hash] the value of each cell of number_cells.xlsx read with the schema, by its name.
      def by_name(schema)
        read_all(IOStreams.path(number_cells).schema(schema), :hash).to_h { |record| [record["name"], record["value"]] }
      end

      it "are the number that the cell holds, so that a string field reads it" do
        records = [
          {"id" => "1001", "amount" => "12.5", "zip" => "01234", "ok" => "true", "note" => "x"},
          {"id" => "7", "amount" => "3", "zip" => "00501", "ok" => "false", "note" => nil}
        ]

        assert_equal records, read_all(IOStreams.path(cells).schema(strings), :hash)
      end

      it "are the same in the lines read, as in the rows" do
        assert_equal ["id,amount,zip,ok,note", "1001,12.5,01234,true,x", "7,3,00501,false"],
                     read_all(IOStreams.path(cells).schema(strings), :line)
        lines = read_all(IOStreams.path(number_cells).schema(values), :line).drop(1)

        assert_equal by_name(values).map { |name, value| CSV.generate_line([name, value], row_sep: "") }, lines
      end

      it "are the 15 significant digits that Excel displays, or every digit of a whole number below 2**53" do
        expected = {
          "n_0.3"           => "0.3",
          "n_1e-7"          => "0.0000001",
          "n_1e15"          => "1000000000000000",
          "n_1.5e20"        => "150000000000000000000",
          "n_card"          => "4111111111111111",
          "n_big_whole"     => "12345678901234600000",
          "n_big_fraction"  => "1000000000000000",
          "n_negative_zero" => "0"
        }

        assert_equal expected, by_name(values).slice(*expected.keys)
      end

      it "are numbers in a cell without a type, as Excel itself writes them, which creek reads as text" do
        assert_equal({"general_2134" => "2134", "general_0.3" => "0.3", "general_1e-7" => "0.0000001"},
                     by_name(values).slice("general_2134", "general_0.3", "general_1e-7"))
      end

      it "are the number without its number format, which creek truncated for a format without decimals" do
        expected = {
          "format_0.00"       => "12.5",
          "format_percent"    => "0.125",
          "format_scientific" => "0.3",
          "format_0"          => "12.5",
          "format_currency"   => "1234.5"
        }

        assert_equal expected, by_name(values).slice(*expected.keys)
      end

      it "are a date in ISO 8601, and a date and time at the time of its clock in UTC, which their fields read" do
        expected = {
          "date"             => "2026-10-25",
          "date_time"        => "2026-10-25T09:30:00Z",
          "date_time_millis" => "2026-10-25T09:30:00.500Z",
          "time"             => "09:30:00",
          "time_after_a_day" => "1899-12-31T12:00:00Z",
          "date_negative"    => "-1"
        }

        assert_equal expected, by_name(values).slice(*expected.keys)
        # The upgrade suite reads them into the fields of their types, see test/upgrade/results_test.rb.
        datetime = IOStreams::Schema::Field.new(name: "at", type: "datetime")

        assert_equal Time.utc(2026, 10, 25, 9, 30, 0.5r), datetime.cast(expected["date_time_millis"])
        assert_equal Date.new(2026, 10, 25), IOStreams::Schema::Field.new(name: "on", type: "date").cast(expected["date"])
      end

      it "are the same in every time zone" do
        original   = ENV.fetch("TZ", nil)
        ENV["TZ"]  = "Asia/Kolkata"
        in_kolkata = by_name(values)
        ENV["TZ"]  = "America/Los_Angeles"

        assert_equal in_kolkata, by_name(values)
      ensure
        ENV["TZ"] = original
      end

      it "keep creek's text of every other cell" do
        expected = {"boolean" => "true", "error" => "#N/A", "formula_text" => "abc", "text_12.0" => "12.0"}

        assert_equal expected, by_name(values).slice(*expected.keys)
      end

      it "are still the text of the Float that creek reads without a schema, as IOStreams 2.1 read them" do
        assert_equal ["id,amount,zip,ok,note", "1001.0,12.5,01234,true,x", "7.0,3.0,00501,false"], read_all(IOStreams.path(cells), :line)
        records = assert_deprecated(/the rows and records of a spreadsheet read without a type for each column are deprecated/) do
          read_all(IOStreams.path(cells), :hash)
        end

        ids = records.map { |record| record["id"] }

        assert_equal %w[1001.0 7.0], ids
        lines = read_all(IOStreams.path(number_cells), :line)

        # The text of creek's Float differs on JRuby, such as "4111111111111111.0" for "4.111111111111111e+15".
        assert_includes lines, "format_0,12"
      end

      it "are read by the schema reader, which the builder opens for a file read with a schema" do
        assert_equal IOStreams::Xlsx::SchemaReader, IOStreams::Xlsx::Reader.schema_reader
        assert_equal IOStreams::Xlsx::SchemaReader, IOStreams::Xlsx::SchemaReader.schema_reader
        assert_equal IOStreams::Xlsx::SchemaReader.option_names, IOStreams::Xlsx::Reader.option_names
        assert_equal IOStreams::Xlsx::SchemaReader.text_format, IOStreams::Xlsx::Reader.text_format
      end

      it "are read by a subclass of the reader itself, such as one that an application registers" do
        subclass = Class.new(IOStreams::Xlsx::Reader)

        assert_equal subclass, subclass.schema_reader
      end
    end

    describe "the date and time cells of a spreadsheet read with a schema" do
      # A workbook of one row of a cell of each number format, each in the column of its name: custom formats of a date,
      # `yyyy-mm-dd` and `dd/mm/yyyy` (of the type n), a date and time, `dd/mm/yyyy hh:mm`, and a time of day,
      # `hh:mm:ss`, Excel's built-in formats of a date (14), a date and time (22, of the type n) and times of day (20,
      # and 21 of the type n), and the numbers of custom formats of a color, `[Red]0.00`, and of quoted text with a `d`
      # or a `y`, `0.00" days"` and `0" yd"` (of the type n), which creek each takes as a date and time.
      let :date_cells do
        File.join(File.dirname(__FILE__), "files", "date_cells.xlsx")
      end

      let :names do
        %w[custom_date custom_dmy custom_date_time custom_time date date_time time_hm time_hms red days year]
      end

      # The text of each cell, as IOStreams 3.0 gives it.
      let :texts do
        {
          "custom_date"      => "2026-10-25",
          "custom_dmy"       => "2026-10-25",
          "custom_date_time" => "2026-10-25T09:30:00Z",
          "custom_time"      => "09:30:05",
          "date"             => "2026-10-25",
          "date_time"        => "2026-10-25T09:30:00Z",
          "time_hm"          => "09:30:00",
          "time_hms"         => "09:30:05",
          "red"              => "12.5",
          "days"             => "3.5",
          "year"             => "7"
        }
      end

      # Returns [Array] what the path yields in the mode.
      def read_all(path, mode)
        rows = []
        path.each(mode) { |row| rows << row }
        rows
      end

      # Returns [IOStreams::Path] the workbook read with a field of each column, of the supplied type, or string.
      def typed(types = {})
        IOStreams.path(date_cells).schema(fields: names.map { |name| {name: name, type: types.fetch(name, "string")} })
      end

      it "are the dates and times of their number formats, as IOStreams 3.0 classifies them, rather than as creek does" do
        assert_equal [texts], read_all(typed, :hash)
      end

      it "are the same in the lines read, as in the rows" do
        assert_equal [names.join(","), texts.values.join(",")], read_all(typed, :line)
      end

      it "are the same in every time zone" do
        original  = ENV.fetch("TZ", nil)
        ENV["TZ"] = "Asia/Kolkata"

        assert_equal [texts], read_all(typed, :hash)
        ENV["TZ"] = "America/Los_Angeles"

        assert_equal [texts], read_all(typed, :hash)
      ensure
        ENV["TZ"] = original
      end

      it "are read by the fields of their types" do
        types = {
          "custom_date" => "date", "custom_dmy" => "date", "date" => "date",
          "custom_date_time" => "datetime", "date_time" => "datetime",
          "red" => "number", "days" => "number", "year" => "integer"
        }
        record = texts.merge(
          "custom_date"      => Date.new(2026, 10, 25),
          "custom_dmy"       => Date.new(2026, 10, 25),
          "date"             => Date.new(2026, 10, 25),
          "custom_date_time" => Time.utc(2026, 10, 25, 9, 30),
          "date_time"        => Time.utc(2026, 10, 25, 9, 30),
          "red"              => BigDecimal("12.5"),
          "days"             => BigDecimal("3.5"),
          "year"             => 7
        )

        assert_equal [record], read_all(typed(types), :hash)
      end

      it "are still creek's text without a schema, as IOStreams 2.1 read them, in the time zone of the process" do
        creek = [
          Time.new(2026, 10, 25), Time.new(2026, 10, 25), Time.new(2026, 10, 25, 9, 30), Time.new(1899, 12, 30, 9, 30, 5),
          "2026-10-25", Time.new(2026, 10, 25, 9, 30), Time.new(1899, 12, 30, 9, 30), Time.new(1899, 12, 30, 9, 30, 5),
          "12.5", Time.new(1900, 1, 2, 12), Time.new(1900, 1, 6)
        ]

        assert_equal [names.join(","), creek.join(",")], read_all(IOStreams.path(date_cells), :line)
      end
    end
  end

  describe IOStreams::Xlsx::SchemaReader do
    describe ".displayed" do
      it "gives a whole number without a decimal point" do
        assert_equal "2134", IOStreams::Xlsx::SchemaReader.displayed(2134.0)
        assert_equal "-7", IOStreams::Xlsx::SchemaReader.displayed(-7.0)
        assert_equal "0", IOStreams::Xlsx::SchemaReader.displayed(-0.0)
        assert_equal "123456789012345", IOStreams::Xlsx::SchemaReader.displayed(123_456_789_012_345.0)
      end

      it "gives every digit of a whole number below 2**53, which a Float holds exactly" do
        assert_equal "4111111111111111", IOStreams::Xlsx::SchemaReader.displayed(4_111_111_111_111_111.0)
        assert_equal "9007199254740991", IOStreams::Xlsx::SchemaReader.displayed(9_007_199_254_740_991.0)
        assert_equal "-9007199254740991", IOStreams::Xlsx::SchemaReader.displayed(-9_007_199_254_740_991.0)
        assert_equal "9007199254740990", IOStreams::Xlsx::SchemaReader.displayed(9_007_199_254_740_992.0)
      end

      it "gives the 15 most significant digits that Excel displays, in plain digits" do
        assert_equal "12.5", IOStreams::Xlsx::SchemaReader.displayed(12.5)
        assert_equal "0.3", IOStreams::Xlsx::SchemaReader.displayed(0.1 + 0.2)
        assert_equal "1", IOStreams::Xlsx::SchemaReader.displayed(1.0000000000000002)
        assert_equal "-0.5", IOStreams::Xlsx::SchemaReader.displayed(-0.5)
        assert_equal "0.0000001", IOStreams::Xlsx::SchemaReader.displayed(1e-7)
        assert_equal "0.00005", IOStreams::Xlsx::SchemaReader.displayed(5e-5)
        assert_equal "150000000000000000000", IOStreams::Xlsx::SchemaReader.displayed(1.5e20)
        assert_equal "1000000000000000", IOStreams::Xlsx::SchemaReader.displayed(999_999_999_999_999.9)
        assert_equal "12345678901234600000", IOStreams::Xlsx::SchemaReader.displayed(12_345_678_901_234_567_890.0)
      end

      it "rounds the exact value of the Float, rather than its text, the same on every Ruby" do
        # The Floats of 0.1234567890123455 and 5.393774484000625e-08 are below their text, which ends in 5.
        assert_equal "0.123456789012345", IOStreams::Xlsx::SchemaReader.displayed(0.1234567890123455)
        assert_equal "0.0000000539377448400062", IOStreams::Xlsx::SchemaReader.displayed(5.393774484000625e-08)
        assert_equal "-72732612300909600", IOStreams::Xlsx::SchemaReader.displayed(-7.273261230090965e+16)
      end

      it "keeps any other value as it is" do
        date = Date.new(2026, 10, 31)

        assert_predicate IOStreams::Xlsx::SchemaReader.displayed(Float::NAN), :nan?
        assert_equal 7, IOStreams::Xlsx::SchemaReader.displayed(7)
        assert_equal BigDecimal("0.12e2"), IOStreams::Xlsx::SchemaReader.displayed(BigDecimal("0.12e2"))
        assert_equal "01234", IOStreams::Xlsx::SchemaReader.displayed("01234")
        assert_same date, IOStreams::Xlsx::SchemaReader.displayed(date)
        assert_nil IOStreams::Xlsx::SchemaReader.displayed(nil)
        assert IOStreams::Xlsx::SchemaReader.displayed(true)
      end
    end

    describe "a version of creek without the methods that IOStreams relies on" do
      it "raises IOStreams::Errors::Error, rather than let creek convert the cells" do
        file   = File.join(File.dirname(__FILE__), "files", "number_cells.xlsx")
        reader = IOStreams::Xlsx::Reader.new(file)
        reader.instance_variable_set(:@worksheet, Object.new)

        error = assert_raises(IOStreams::Errors::Error) { reader.send(:convert_cells) { nil } }
        assert_includes error.message, "Creek::Sheet#convert"
      end

      it "raises IOStreams::Errors::Error without Creek::Sheet#book, rather than let creek classify the number formats" do
        file   = File.join(File.dirname(__FILE__), "files", "date_cells.xlsx")
        reader = IOStreams::Xlsx::Reader.new(file)
        reader.instance_variable_set(:@worksheet, Object.new)

        error = assert_raises(IOStreams::Errors::Error) { reader.send(:number_formats) }
        assert_includes error.message, "Creek::Styles#styles_xml"
      end
    end
  end

  describe IOStreams::Xlsx::Cells do
    describe ".custom_format" do
      it "classifies the number formats of Excel, rather than as the gem that reads them does" do
        assert_equal :date, IOStreams::Xlsx::Cells.custom_format("yyyy\\-mm\\-dd")
        assert_equal :date, IOStreams::Xlsx::Cells.custom_format("d-mmm-yy")
        assert_equal :date_time, IOStreams::Xlsx::Cells.custom_format("m/d/yy h:mm")
        assert_equal :time, IOStreams::Xlsx::Cells.custom_format("h:mm AM/PM")
        assert_equal :time, IOStreams::Xlsx::Cells.custom_format("mm:ss")
        assert_nil IOStreams::Xlsx::Cells.custom_format("0.00")
        assert_nil IOStreams::Xlsx::Cells.custom_format("[Red]#,##0.00")
        assert_nil IOStreams::Xlsx::Cells.custom_format('"days" 0')
      end

      it "classifies a format code by what its sections in brackets leave, also one whose brackets never close" do
        assert_equal :date, IOStreams::Xlsx::Cells.custom_format("[$-409][Blue]mmmm d, yyyy")
        assert_equal :time, IOStreams::Xlsx::Cells.custom_format("[h]:mm:ss")
        assert_nil IOStreams::Xlsx::Cells.custom_format("[>=100]0;0")
        assert_nil IOStreams::Xlsx::Cells.custom_format("[" * 40_000)
      end

      it "classifies the common custom formats of a date, a date and time, and a time of day" do
        assert_equal :date, IOStreams::Xlsx::Cells.custom_format("yyyy-mm-dd")
        assert_equal :date, IOStreams::Xlsx::Cells.custom_format("dd/mm/yyyy")
        assert_equal :date_time, IOStreams::Xlsx::Cells.custom_format("dd/mm/yyyy hh:mm")
        assert_equal :date_time, IOStreams::Xlsx::Cells.custom_format("yyyy-mm-dd hh:mm:ss.000")
        assert_equal :time, IOStreams::Xlsx::Cells.custom_format("hh:mm:ss")
        assert_nil IOStreams::Xlsx::Cells.custom_format("[Red]0.00")
        assert_nil IOStreams::Xlsx::Cells.custom_format('0.00" days"')
        assert_nil IOStreams::Xlsx::Cells.custom_format("0\\y")
      end
    end

    describe ".number_formats" do
      it "has none for a workbook without styles" do
        assert_equal [], IOStreams::Xlsx::Cells.number_formats(nil)
      end
    end

    describe ".date_text" do
      let(:base_date) { Date.new(1899, 12, 30) }

      it "is nil for a number of a format that is not a date or a time, or that is not a date that Excel holds" do
        assert_nil IOStreams::Xlsx::Cells.date_text("46320", nil, base_date)
        assert_nil IOStreams::Xlsx::Cells.date_text("-1", :date, base_date)
        assert_nil IOStreams::Xlsx::Cells.date_text("2958466", :date_time, base_date)
        assert_nil IOStreams::Xlsx::Cells.date_text("1e400", :date, base_date)
      end

      it "is the date of a date and time of a time format of a day or more, and the first day of the workbook" do
        assert_equal "1899-12-31T12:00:00Z", IOStreams::Xlsx::Cells.date_text("1.5", :time, base_date)
        assert_equal "2030-10-26", IOStreams::Xlsx::Cells.date_text("46320", :date, Date.new(1904, 1, 1))
      end
    end
  end
end
