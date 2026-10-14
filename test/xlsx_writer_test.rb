# frozen_string_literal: true

require_relative "test_helper"
require "csv"

class XlsxWriterTest < Minitest::Test
  describe IOStreams::Xlsx::Writer do
    let :dir do
      Dir.mktmpdir("iostreams")
    end

    let :file_name do
      File.join(dir, "spreadsheet.xlsx")
    end

    let :rows do
      [
        ["name", "zip", "notes"],
        ["Jack", "01234", "first, second"],
        ["Jill", "98101", "said \"hi\""],
        ["Zoë", "", "é"]
      ]
    end

    after do
      FileUtils.rm_rf(dir)
    end

    # Returns [Array<Array>] the rows read back from the workbook in the supplied data.
    def read_rows(data)
      IOStreams::Xlsx::Reader.stream(StringIO.new(data)) { |io| CSV.parse(io.read.force_encoding(Encoding::UTF_8)) }
    end

    def write(output = StringIO.new(+""), **options, &)
      IOStreams::Xlsx::Writer.stream(output, **options, &)
      output.string
    end

    def worksheet_xml(data, entry = "xl/worksheets/sheet1.xml")
      IOStreams.stream(StringIO.new(data)).stream(:zip, entry_file_name: entry).read
    end

    describe ".stream" do
      it "writes CSV text as the rows of a workbook" do
        data = write { |io| io.write(rows.map(&:to_csv).join) }

        assert_equal rows.map { |row| row.map { |value| value == "" ? nil : value } }, read_rows(data)
      end

      it "writes a record that is split across writes" do
        csv  = rows.map(&:to_csv).join
        data = write { |io| csv.each_char { |char| io.write(char) } }

        assert_equal rows.map { |row| row.map { |value| value == "" ? nil : value } }, read_rows(data)
      end

      it "writes a quoted value that contains a newline" do
        skip "creek on JRuby reads an inline string only up to its first newline" if defined?(JRuby)

        data = write { |io| io.write("a,\"multi\nline \"\"quoted\"\"\"\nb,c\n") }

        assert_equal [["a", "multi\nline \"quoted\""], %w[b c]], read_rows(data)
      end

      it "writes a quoted value that contains a newline with use_shared_strings" do
        data = write(use_shared_strings: true) { |io| io.write("a,\"multi\nline\"\n") }

        assert_equal [%W[a multi\nline]], read_rows(data)
      end

      it "writes the last record without a newline" do
        data = write { |io| io << "a,b\n" << "c,d" }

        assert_equal [%w[a b], %w[c d]], read_rows(data)
      end

      it "writes records ending with a carriage return and newline" do
        data = write { |io| io.write("a,b\r\nc,d\r\n") }

        assert_equal [%w[a b], %w[c d]], read_rows(data)
      end

      it "writes records ending with a carriage return" do
        data = write { |io| io.write("a,b\rc,d\re,f") }

        assert_equal [%w[a b], %w[c d], %w[e f]], read_rows(data)
      end

      it "writes the last record ending with a carriage return" do
        data = write { |io| io.write("a,b\rc,d\r") }

        assert_equal [%w[a b], %w[c d]], read_rows(data)
      end

      it "writes a carriage return and newline that are split across writes" do
        data = write do |io|
          io.write("a,b\r")
          io.write("\nc,d\r")
          io.write("\n")
        end

        assert_equal [%w[a b], %w[c d]], read_rows(data)
      end

      it "writes a newline within a quoted value of a record that ends with a carriage return and newline" do
        skip "creek on JRuby reads an inline string only up to its first newline" if defined?(JRuby)

        data = write { |io| io.write("a,\"multi\nline\"\r\nb,c\r\n") }

        assert_equal [%W[a multi\nline], %w[b c]], read_rows(data)
      end

      it "writes a carriage return within a quoted value of a record that ends with a carriage return" do
        data = write(use_shared_strings: true) { |io| io.write("a,\"multi\rline\"\rb,c\r") }

        # XML reads a line break within a value as a newline.
        assert_equal [%W[a multi\nline], %w[b c]], read_rows(data)
      end

      it "writes binary text as UTF-8" do
        data = write { |io| io.write("Zoë,é\n".b) }

        assert_equal [%w[Zoë é]], read_rows(data)
      end

      it "returns the number of bytes written" do
        write { |io| assert_equal "Zoë,é\n".bytesize, io.write("Zoë,é\n") }
      end

      it "returns the result of the block" do
        assert_equal 5, IOStreams::Xlsx::Writer.stream(StringIO.new(+"")) { 5 }
      end

      it "writes a workbook with an empty worksheet when nothing is written" do
        data = write { |_io| nil }

        assert_equal [], read_rows(data)
        assert_includes worksheet_xml(data), "<sheetData></sheetData>"
      end

      it "raises when the data ends within a quoted value" do
        assert_raises(CSV::MalformedCSVError) { write { |io| io.write("a,\"b\n") } }
      end

      it "writes every value as text by default" do
        data = write { |io| io.write("1.5,2026-10-09,true\n") }

        assert_equal [%w[1.5 2026-10-09 true]], read_rows(data)
        refute_includes worksheet_xml(data), "t=\"n\""
      end

      it "writes numbers, dates and booleans with auto_format" do
        xml = worksheet_xml(write(auto_format: true) { |io| io.write("1.5,2026-10-09,true\n") })

        assert_includes xml, "<c r=\"A1\" t=\"n\"><v>1.5</v></c>"
        assert_includes xml, "<c r=\"B1\" s=\"1\">"
        assert_includes xml, "<c r=\"C1\" t=\"b\"><v>1</v></c>"
      end

      it "names the worksheet Sheet1 by default" do
        xml = worksheet_xml(write { |io| io.write("a\n") }, "xl/workbook.xml")

        assert_includes xml, "<sheet name=\"Sheet1\""
      end

      it "names the worksheet with sheet_name" do
        xml = worksheet_xml(write(sheet_name: "Q&A") { |io| io.write("a\n") }, "xl/workbook.xml")

        assert_includes xml, "<sheet name=\"Q&amp;A\""
      end

      it "accepts the name of a worksheet that Excel accepts" do
        ["Sheet1", "Q&A", "it's", "Données", "x" * 31, nil].each do |sheet_name|
          assert_nil IOStreams::Xlsx::Writer.check(sheet_name: sheet_name)
        end
      end

      it "raises for the name of a worksheet that Excel rejects" do
        {
          ""        => "Excel rejects an empty name for a worksheet",
          "x" * 32  => "Excel rejects the name of a worksheet that is longer than 31 characters",
          "Q1/Q2"   => "Excel rejects the name of a worksheet that contains any of [ ] : * ? / \\",
          "a\\b"    => "Excel rejects the name of a worksheet that contains any of [ ] : * ? / \\",
          "[draft]" => "Excel rejects the name of a worksheet that contains any of [ ] : * ? / \\",
          "10:30"   => "Excel rejects the name of a worksheet that contains any of [ ] : * ? / \\",
          "*"       => "Excel rejects the name of a worksheet that contains any of [ ] : * ? / \\",
          "Why?"    => "Excel rejects the name of a worksheet that contains any of [ ] : * ? / \\",
          "'quoted" => "Excel rejects the name of a worksheet that starts or ends with an apostrophe",
          "quoted'" => "Excel rejects the name of a worksheet that starts or ends with an apostrophe",
          :Totals   => "supply the name of the worksheet as a String"
        }.each_pair do |sheet_name, problem|
          error = assert_raises(ArgumentError) { IOStreams::Xlsx::Writer.check(sheet_name: sheet_name) }
          assert_equal "Invalid sheet_name #{sheet_name.inspect}: #{problem}", error.message
          assert_raises(ArgumentError) { write(sheet_name: sheet_name) { |io| io.write("a\n") } }
        end
      end

      it "stores the values in a shared string table with use_shared_strings" do
        data = write(use_shared_strings: true) { |io| io.write("a,a\nb,a\n") }

        assert_equal [%w[a a], %w[b a]], read_rows(data)
        assert_includes worksheet_xml(data, "xl/sharedStrings.xml"), "uniqueCount=\"2\""
      end

      it "writes to an output that cannot seek" do
        data   = +"".b
        output = Object.new
        output.define_singleton_method(:write) do |chunk|
          data << chunk.b
          chunk.bytesize
        end

        IOStreams::Xlsx::Writer.stream(output) { |io| io.write("a,b\n") }

        assert_equal [%w[a b]], read_rows(data)
      end
    end

    describe "via a path" do
      it "writes and reads rows" do
        IOStreams.path(file_name).writer(:array) do |io|
          io << %w[name amount]
          io << ["Jack", 1.5]
        end

        records = []
        IOStreams.path(file_name).each(:hash) { |record| records << record }

        assert_equal [{"name" => "Jack", "amount" => "1.5"}], records
      end

      it "writes hashes with a header row" do
        IOStreams.path(file_name).writer(:hash) { |io| io << {"name" => "Jack", "zip" => "01234"} }

        assert_equal [%w[name zip], %w[Jack 01234]], read_rows(File.binread(file_name))
      end

      it "accepts the writer options" do
        IOStreams.path(file_name).option(:xlsx, sheet_name: "Totals", use_shared_strings: true).writer(:array) do |io|
          io << %w[a b]
        end

        assert_equal [%w[a b]], read_rows(File.binread(file_name))
      end

      it "ignores auto_format and use_shared_strings when reading" do
        path = IOStreams.path(file_name).option(:xlsx, auto_format: true, use_shared_strings: true)
        path.writer(:array) { |io| io << %w[a 01234] }

        rows = []
        path.each(:array) { |row| rows << row }

        # A number written with auto_format is read back as a float.
        assert_equal [%w[a 1234.0]], rows
      end

      it "keeps an existing file when the name of the worksheet is rejected" do
        File.write(file_name, "precious")

        assert_raises(ArgumentError) do
          IOStreams.path(file_name).option(:xlsx, sheet_name: "Q1/Q2").writer(:array) { |io| io << %w[a b] }
        end
        assert_equal "precious", File.read(file_name)
      end

      it "raises for sheet_name when reading" do
        IOStreams.path(file_name).writer(:array) { |io| io << %w[a] }

        error = assert_raises(ArgumentError) do
          IOStreams.path(file_name).option(:xlsx, sheet_name: "Totals").each(:array) { |_row| nil }
        end
        assert_match(/:sheet_name only applies when writing a :xlsx stream/, error.message)
      end

      it "writes lines delimited by a carriage return" do
        IOStreams.path(file_name).writer(:line, delimiter: "\r") do |io|
          io << "a,b"
          io << "c,d"
          io << "e,f"
        end

        rows = []
        IOStreams.path(file_name).each(:array) { |row| rows << row }

        assert_equal [%w[a b], %w[c d], %w[e f]], rows
      end

      it "writes rows delimited by a carriage return and newline, or a carriage return" do
        ["\r\n", "\r"].each do |delimiter|
          IOStreams.path(file_name).writer(:array, delimiter: delimiter) do |io|
            io << %w[a b]
            io << %w[c d]
          end

          rows = []
          IOStreams.path(file_name).each(:array) { |row| rows << row }

          assert_equal [%w[a b], %w[c d]], rows, delimiter.inspect
        end
      end

      it "reads empty cells as empty values, without those at the end of a row" do
        IOStreams.path(file_name).writer(:array) do |io|
          io << ["a", "", "c"]
          io << ["", "", ""]
          io << ["x", "", ""]
          io << ["", "y"]
        end

        assert_equal "a,,c\n\nx\n,y\n", IOStreams.path(file_name).read
      end

      it "writes within another stream" do
        path = IOStreams.path(File.join(dir, "spreadsheet.xlsx.gz"))
        path.writer(:array) { |io| io << %w[a b] }

        rows = []
        path.each(:array) { |row| rows << row }

        assert_equal [%w[a b]], rows
      end
    end

    describe "the format of the rows" do
      it "writes each value into its own cell, whatever format the file name names before the extension" do
        path = IOStreams.path(File.join(dir, "report.psv.xlsx"))
        path.writer(:array) do |io|
          io << %w[id name]
          io << [1, "Smith, Jack"]
        end

        assert_equal [%w[id name], ["1", "Smith, Jack"]], read_rows(File.binread(path.to_s))
      end

      it "reads each cell as a value, whatever format the file name names before the extension" do
        File.binwrite(File.join(dir, "report.json.xlsx"), write { |io| io << "id,name\n1,\"Smith, Jack\"\n" })

        records = []
        IOStreams.path(File.join(dir, "report.json.xlsx")).each(:hash) { |record| records << record }

        assert_equal [{"id" => "1", "name" => "Smith, Jack"}], records
      end

      it "is CSV" do
        assert_equal :csv, IOStreams.path("report.xlsx").format
        assert_equal :csv, IOStreams.path("report.psv.xlsm.pgp").format
      end

      it "raises for another format set on the path, before the file is opened" do
        path  = IOStreams.path(file_name).format(:json)
        error = assert_raises(ArgumentError) { path.writer(:hash) { |io| io << {"a" => 1} } }

        assert_equal "The format of the rows cannot be :json, since the streams read and write them as :csv. " \
                     "Set the format to :csv, or to nil.", error.message
        refute_path_exists file_name
        assert_raises(ArgumentError) { path.each(:line) { |_line| nil } }
        assert_raises(ArgumentError) { IOStreams.path(file_name).format(:psv).each(:array) { |_row| nil } }
      end

      it "keeps a line break within a cell in its line" do
        skip "creek on JRuby reads an inline string only up to its first newline" if defined?(JRuby)

        IOStreams.path(file_name).writer(:array) do |io|
          io << %w[id note]
          io << ["1", "line one\nline two"]
        end

        lines = []
        IOStreams.path(file_name).each(:line) { |line| lines << line }

        assert_equal ["id,note", "1,\"line one\nline two\""], lines
      end
    end
  end
end
