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
      # The CSV text ends each row with a newline, which CSV would otherwise guess from the first line break, such as a
      # carriage return within a value.
      IOStreams::Xlsx::Reader.stream(StringIO.new(data)) do |io|
        CSV.parse(io.read.force_encoding(Encoding::UTF_8), row_sep: "\n")
      end
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
        data = write { |io| io.write("a,\"multi\nline\"\r\nb,c\r\n") }

        assert_equal [%W[a multi\nline], %w[b c]], read_rows(data)
      end

      it "writes a carriage return within a quoted value of a record that ends with a carriage return" do
        data = write(use_shared_strings: true) { |io| io.write("a,\"multi\rline\"\rb,c\r") }

        assert_equal [%W[a multi\rline], %w[b c]], read_rows(data)
      end

      it "writes binary text as UTF-8" do
        data = write { |io| io.write("Zoë,é\n".b) }

        assert_equal [%w[Zoë é]], read_rows(data)
      end

      it "writes text in another encoding as UTF-8, such as that of #puts, which writes each object in its own encoding" do
        data = write { |io| io.puts("name", "caf\xE9".b.force_encoding("Windows-1252"), "a,b".encode("UTF-16LE")) }

        assert_equal [["name"], ["caf\u{e9}"], %w[a b]], read_rows(data)
      end

      it "raises InvalidEncoding for text in another encoding that UTF-8 cannot hold" do
        error = assert_raises(IOStreams::Errors::InvalidEncoding) do
          write { |io| io.write("a\x81\n".b.force_encoding("Windows-1252")) }
        end

        assert_match(/\AIn a String of CSV text written to a spreadsheet, "\\x81" in WINDOWS-1252 has no UTF-8 character at byte offset 1\z/, error.message)
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

      it "raises when the data ends within a quoted value, as the csv gem's error tagged with the line that it starts on" do
        error = assert_raises(IOStreams::Errors::RowError) { write { |io| io.write("x,y\na,\"b\n") } }

        assert_kind_of CSV::MalformedCSVError, error
        assert_equal "Unclosed quoted field, on line 2", error.message
        assert_equal 2, error.line_number
        assert_nil error.record_number
      end

      it "raises for a record whose quoting is not valid, as the csv gem's error tagged with the line that it starts on" do
        error = assert_raises(IOStreams::Errors::RowError) { write { |io| io.write("a,b\nx\"y,z\nc,d\n") } }

        assert_kind_of CSV::MalformedCSVError, error
        assert_equal "Illegal quoting, on line 2", error.message
        assert_equal "Illegal quoting", error.reason
        assert_equal 2, error.line_number
      end

      it "counts the line breaks within the quoted values of the records before one whose quoting is not valid" do
        csv = "a,\"one\ntwo\"\r\nb,\"three\r\nfour\rfive\"\r\n\"c\"d,e\r\n"
        [[csv], csv.chars].each do |writes|
          error = assert_raises(IOStreams::Errors::RowError) { write { |io| writes.each { |text| io.write(text) } } }

          assert_equal 6, error.line_number, writes.size
          assert_equal "Any value after quoted field isn't allowed, on line 6", error.message
        end
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

        # A number is written as a number, and read back as the Float that Excel holds.
        assert_equal [{"name" => "Jack", "amount" => 1.5}], records
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

        # Text written without a schema with auto_format, whose type is not known, is written as the number that it looks
        # like, and read back as the Float that Excel holds.
        assert_equal [["a", 1234.0]], rows
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

      it "raises for a line whose quoting is not valid, as the csv gem's error tagged with its line" do
        error = assert_raises(IOStreams::Errors::RowError) do
          IOStreams.path(file_name).writer(:line) do |io|
            io << "a,b"
            io << "c,d"
            io << %(e"f,g)
          end
        end

        assert_kind_of CSV::MalformedCSVError, error
        assert_equal "Illegal quoting, on line 3", error.message
      end

      it "raises for a line of a CSV file copied whose quoting is not valid, as the csv gem's error tagged with its line" do
        source = IOStreams.path(dir, "source.csv")
        source.write(%(a,b\n"c"d,e\n))

        error = assert_raises(IOStreams::Errors::RowError) { IOStreams.path(file_name).copy_from(source) }

        assert_kind_of CSV::MalformedCSVError, error
        assert_equal 2, error.line_number
      end

      it "raises for a delimiter of the rows written, which are cells rather than lines" do
        ["\r\n", "\r"].each do |delimiter|
          error = assert_raises(ArgumentError) do
            IOStreams.path(file_name).writer(:array, delimiter: delimiter) { |io| io << %w[a b] }
          end

          assert_includes error.message, "rather than lines of text"
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

    describe "a time of day" do
      let(:schema) do
        {
          fields: [
            {name: "starts", type: "time"},
            {name: "ny", type: "time", timeZone: "America/New_York"},
            {name: "at", type: "datetime"}
          ]
        }
      end

      it "writes the clock of a time field as a cell of a time of day, Excel's format h:mm:ss, which reads back" do
        path = IOStreams.path(file_name).schema(schema)
        path.writer(:hash) do |io|
          io << {"starts" => Time.new(2000, 1, 1, 9, 30, 0.5r, "+05:00"), "ny" => Time.utc(2000, 1, 1, 14, 30),
                 "at" => Time.utc(2026, 7, 1, 9, 30)}
        end
        data = File.binread(file_name)

        assert_includes worksheet_xml(data, "xl/styles.xml"), '<xf numFmtId="21" '
        assert_match(/<c r="A2" s="3"><v>0\.39/, worksheet_xml(data))
        assert_match(/<c r="C2" s="2"><v>46204\.39/, worksheet_xml(data))
        records = []
        path.each(:hash) { |record| records << record }

        assert_equal [{"starts" => Time.utc(2000, 1, 1, 9, 30, 0.5r), "ny" => Time.utc(2000, 1, 1, 14, 30),
                       "at" => Time.utc(2026, 7, 1, 9, 30)}], records
        lines = []
        IOStreams.path(file_name).each(:line) { |line| lines << line }

        assert_equal "09:30:00.500,09:30:00", lines.last.split(",").first(2).join(",")
        strings = []
        IOStreams.path(file_name).schema(fieldsMatch: "subset", fields: [{name: "starts", type: "string"}]).each(:hash) do |record|
          strings << record
        end

        assert_equal "09:30:00.500", strings.first["starts"]
      end

      it "writes a time of day below 8.64 seconds, which Ruby writes with an exponent, and midnight, as a time of day" do
        path  = IOStreams.path(file_name).schema(schema.merge(fieldsMatch: "subset"))
        times = [Time.utc(2000, 1, 1), Time.utc(2000, 1, 1, 0, 0, 1), Time.utc(2000, 1, 1, 0, 0, 0.001r)]
        path.writer(:hash) do |io|
          times.each { |time| io << {"starts" => time} }
        end
        xml = worksheet_xml(File.binread(file_name))

        assert_match(/<c r="A3" s="3"><v>1\.\d+e-05</, xml)
        assert_match(/<c r="A4" s="3"><v>1\.\d+e-08</, xml)
        assert_equal 3, xml.scan('s="3"').size
        records = []
        path.each(:hash) { |record| records << record["starts"] }

        assert_equal times, records
        lines = []
        IOStreams.path(file_name).each(:line) { |line| lines << line }

        assert_equal(["00:00:00", "00:00:01", "00:00:00.001"], lines.drop(1).map { |line| line.split(",").first })
      end

      it "writes a date and time before 1900-01-01, whose number would be that of a time of day, as its text" do
        path = IOStreams.path(file_name).schema(schema.merge(fields: schema[:fields] + [{name: "any", type: "any"}]))
        path.option(:xlsx, auto_format: true).writer(:hash) do |io|
          io << {"starts" => Time.utc(2000, 1, 1, 12), "ny" => nil, "at" => Time.utc(1899, 12, 30, 12),
                 "any" => "1899-12-30T06:00:00"}
          io << {"starts" => nil, "ny" => nil, "at" => Time.utc(1900, 1, 1), "any" => Time.utc(1899, 12, 31, 6)}
        end
        xml = worksheet_xml(File.binread(file_name))

        assert_match(%r{<c r="A2" s="3"><v>0\.5</v>}, xml)
        assert_includes xml, "<t>1899-12-30T12:00:00</t>"
        assert_includes xml, "<t>1899-12-30T06:00:00</t>"
        assert_includes xml, "<t>1899-12-31T06:00:00</t>"
        assert_match(%r{<c r="C3" s="2"><v>1\.0</v>}, xml)
        records = []
        path.each(:hash) { |record| records << record.slice("at") }

        assert_equal [{"at" => Time.utc(1899, 12, 30, 12)}, {"at" => Time.utc(1900, 1, 1)}], records
      end

      it "writes the time of day of a time field with shared strings and auto_format" do
        path = IOStreams.path(file_name).schema(fields: [{name: "starts", type: "time"}, {name: "notes", type: "any"}])
        path.option(:xlsx, use_shared_strings: true, auto_format: true).writer(:array) do |io|
          io << [Time.utc(2000, 1, 1, 9, 30), "1.5"]
        end
        data = File.binread(file_name)

        assert_match(/<c r="A2" s="3"><v>0\.39/, worksheet_xml(data))
        assert_includes worksheet_xml(data), '<c r="B2" t="n"><v>1.5</v>'
        assert_includes worksheet_xml(data, "xl/sharedStrings.xml"), "<t>starts</t>"
        records = []
        path.each(:hash) { |record| records << record }

        assert_equal [{"starts" => Time.utc(2000, 1, 1, 9, 30), "notes" => 1.5}], records
      end

      it "writes the time of day of a time field, whose style every workbook has" do
        IOStreams.path(file_name).schema(fields: [{name: "at", type: "datetime"}]).writer(:array) do |io|
          io << [Time.utc(2026, 7, 1, 9, 30)]
        end

        assert_includes worksheet_xml(File.binread(file_name), "xl/styles.xml"), '<cellXfs count="4">'
        assert_includes worksheet_xml(File.binread(file_name), "xl/styles.xml"), 'numFmtId="21"'
      end
    end

    describe "Excel's limits" do
      it "raises for a value after Excel's last column, and discards the workbook" do
        File.write(file_name, "existing")
        error = assert_raises(IOStreams::Errors::Error) do
          IOStreams.path(file_name).writer(:array) { |io| io << ["a", *Array.new(16_383), "b"] }
        end

        assert_equal "A worksheet holds at most 16384 columns, to XFD, as Excel limits it, which a value of row 1, in " \
                     "column 16385, exceeds", error.message
        refute_path_exists file_name
      end

      it "writes a value in the last column, and nils after it" do
        data = write(rows: true) { |io| io << [*Array.new(16_383), "last", nil, nil] }

        assert_includes worksheet_xml(data), '<c r="XFD1" t="inlineStr">'
      end
    end

    describe "the text of a cell" do
      let :texts do
        ["a\r\nb\rc", " padded ", "_x0041_ stays", "bell\u0007", "<b> & </b>", "tab\tnew\nline"]
      end

      it "is written as Excel escapes it, and read back as it was" do
        data = write(rows: true) { |io| io << texts }
        xml  = worksheet_xml(data)

        assert_includes xml, "a_x000D_\nb_x000D_c"
        assert_includes xml, '<t xml:space="preserve"> padded </t>'
        assert_includes xml, "_x005F_x0041_ stays"
        assert_includes xml, "bell_x0007_"
        assert_includes xml, "&lt;b&gt; &amp; &lt;/b&gt;"
        assert_equal [texts], read_rows(data)
      end

      it "is written once in the shared strings, and read back as it was" do
        data = write(rows: true, use_shared_strings: true) do |io|
          io << texts
          io << texts
        end

        assert_includes worksheet_xml(data), '<c r="A2" t="s"><v>0</v></c>'
        assert_includes worksheet_xml(data, "xl/sharedStrings.xml"), 'count="12" uniqueCount="6"'
        assert_equal [texts, texts], read_rows(data)
      end

      it "is written to each workbook on its own" do
        first  = write(rows: true) { |io| io << ["first"] }
        second = write(rows: true) { |io| io << ["second"] }

        assert_equal [["first"]], read_rows(first)
        assert_equal [["second"]], read_rows(second)
        assert_equal 1, worksheet_xml(second).scan("<worksheet").size
      end

      it "raises InvalidEncoding for text that is not valid in its encoding, naming the byte" do
        error = assert_raises(IOStreams::Errors::InvalidEncoding) { write(rows: true) { |io| io << ["caf\xE9"] } }

        assert_equal "In the text of a cell, \"\\xE9\" is not valid UTF-8 at byte offset 3", error.message
        assert_equal 3, error.byte_offset
      end

      it "writes binary text of UTF-8 as its text, and text of another encoding converted" do
        data = write(rows: true) { |io| io << ["café".b, "café".encode("Windows-1252")] }

        assert_equal [%w[café café]], read_rows(data)
      end
    end

    describe "a date that Excel cannot show" do
      it "is written as its text, for a time within half a millisecond of the year 10000, which a cell would round to it" do
        data = write(rows: true) { |io| io << [Time.utc(9999, 12, 31, 23, 59, 59.9999r), Time.utc(9999, 12, 31, 23, 59, 59.999r)] }
        xml  = worksheet_xml(data)

        assert_includes xml, '<c r="A1" t="inlineStr"><is><t>9999-12-31T23:59:59.999900</t></is></c>'
        assert_match(/<c r="B1" s="2"><v>2958465\.99999/, xml)
      end

      it "is the date before 1900-03-01 that Excel shows, though it counts 1900-02-29, and reads back as written" do
        dates = (Date.new(1900, 1, 1)..Date.new(1900, 3, 2)).to_a
        times = dates.map { |date| Time.utc(date.year, date.month, date.day, 18) }
        data  = write(rows: true) { |io| dates.zip(times).each { |row| io << row } }
        xml   = worksheet_xml(data)

        assert_includes xml, '<c r="A1" s="1"><v>1</v></c><c r="B1" s="2"><v>1.75</v></c>'
        assert_includes xml, '<c r="A59" s="1"><v>59</v></c><c r="B59" s="2"><v>59.75</v></c>'
        assert_includes xml, '<c r="A60" s="1"><v>61</v></c><c r="B60" s="2"><v>61.75</v></c>'
        expected = dates.map { |date| [date.iso8601, "#{date.iso8601}T18:00:00"] }

        assert_equal expected, read_rows(data)
      end

      it "is written as its text by the worksheet itself, whoever gives it the value" do
        output    = StringIO.new(+"")
        worksheet = IOStreams::Xlsx::WorksheetWriter.new(output, styles:      IOStreams::Xlsx::CellStyles.new,
                                                                 date_system: IOStreams::Xlsx::DateSystem::SYSTEM_1900)
        worksheet << [Date.new(1899, 12, 31), Time.utc(1899, 12, 31, 12), Date.new(1800, 1, 1), Date.new(1900, 1, 1)]
        worksheet.close

        assert_includes output.string, '<c r="A1" t="inlineStr"><is><t>1899-12-31</t></is></c>'
        assert_includes output.string, '<c r="B1" t="inlineStr"><is><t>1899-12-31T12:00:00</t></is></c>'
        assert_includes output.string, '<c r="C1" t="inlineStr"><is><t>1800-01-01</t></is></c>'
        assert_includes output.string, '<c r="D1" s="1"><v>1</v></c>'
      end

      it "decides by the clock that it writes of a time of another offset, as its cell holds it" do
        output    = StringIO.new(+"")
        worksheet = IOStreams::Xlsx::WorksheetWriter.new(output, styles:      IOStreams::Xlsx::CellStyles.new,
                                                                 date_system: IOStreams::Xlsx::DateSystem::SYSTEM_1900)
        worksheet << [Time.new(1899, 12, 31, 22, 0, 0, "-05:00"), Time.new(1900, 1, 1, 2, 0, 0, "+05:00"),
                      Time.new(10_000, 1, 1, 2, 0, 0, "+05:00")]
        worksheet.close

        assert_includes output.string, '<c r="A1" t="inlineStr"><is><t>1899-12-31T22:00:00</t></is></c>'
        assert_match(/<c r="B1" s="2"><v>1\.083333/, output.string)
        assert_includes output.string, '<c r="C1" t="inlineStr"><is><t>10000-01-01T02:00:00</t></is></c>'
      end

      it "is written as its text, which a date field reads back, from rows and from auto_format alike" do
        path = IOStreams.path(file_name).schema(fields: [{name: "on", type: "date"}, {name: "any", type: "any"}])
        path.option(:xlsx, auto_format: true).writer(:array) do |io|
          io << [Date.new(1899, 12, 31), "1899-12-29"]
          io << [Date.new(1900, 1, 1), "1900-01-01"]
          io << [Date.new(1600, 1, 1), "2026-01-02"]
          io << [Date.new(10_000, 1, 1), "9999-12-31"]
          io << [Date.new(9999, 12, 31), "9999-12-31T23:00:00-05:00"]
        end
        xml = worksheet_xml(File.binread(file_name))

        assert_includes xml, "<t>1899-12-31</t>"
        assert_includes xml, "<t>1899-12-29</t>"
        assert_includes xml, "<t>1600-01-01</t>"
        assert_includes xml, "<t>10000-01-01</t>"
        assert_includes xml, "<t>9999-12-31T23:00:00-05:00</t>"
        assert_includes xml, '<c r="A6" s="1"><v>2958465</v></c>'

        assert_match(%r{<c r="A3" s="1"><v>1</v></c><c r="B3" s="1"><v>1</v></c>}, xml)
        refute_match(/<v>-/, xml)
        # A date field reads the text of a date of the year 10000 no more than CSV holds it, so only the rows before it.
        records = []
        path.each(:hash) do |record|
          records << record["on"]
          break if records.size == 3
        end

        assert_equal [Date.new(1899, 12, 31), Date.new(1900, 1, 1), Date.new(1600, 1, 1)], records
      end
    end

    describe "a number field with decimals" do
      it "is written in a number format of that many decimals, and read back as its number" do
        schema = {
          fields: [
            {name: "amount", type: "number", decimals: 2},
            {name: "rate", type: "number", decimals: 4},
            {name: "count", type: "number", decimals: 0},
            {name: "plain", type: "number"},
            {name: "note", type: "string"}
          ]
        }
        path = IOStreams.path(file_name).schema(schema)
        path.writer(:hash) do |io|
          io << {"amount" => BigDecimal("12.5"), "rate" => 0.03, "count" => 7, "plain" => 1.5, "note" => "a"}
          io << {"amount" => nil, "rate" => 1, "count" => 3.0, "plain" => 2, "note" => "12"}
        end
        data   = File.binread(file_name)
        styles = worksheet_xml(data, "xl/styles.xml")

        assert_includes styles, '<numFmt numFmtId="166" formatCode="0.00"/>'
        assert_includes styles, '<numFmt numFmtId="167" formatCode="0.0000"/>'
        assert_includes styles, '<numFmt numFmtId="168" formatCode="0"/>'
        assert_includes styles, '<cellXfs count="7">'
        assert_includes worksheet_xml(data), '<c r="A2" s="4"><v>12.5</v></c><c r="B2" s="5"><v>0.03</v></c>'
        assert_includes worksheet_xml(data), '<c r="D2" t="n"><v>1.5</v></c>'
        records = []
        path.each(:hash) { |record| records << record }

        assert_equal [
          {"amount" => BigDecimal("12.5"), "rate" => BigDecimal("0.03"), "count" => 7, "plain" => 1.5, "note" => "a"},
          {"amount" => nil, "rate" => 1, "count" => 3, "plain" => 2, "note" => "12"}
        ], records
      end

      it "is written as the digits of a BigDecimal smaller than a double holds, rather than 0" do
        tiny = BigDecimal("1e-400")
        path = IOStreams.path(file_name).schema(fields: [{name: "amount", type: "number"}])
        path.writer(:hash) { |io| io << {"amount" => tiny} }
        records = []
        path.each(:hash) { |record| records << record }

        assert_includes worksheet_xml(File.binread(file_name)), "<t>0.#{'0' * 399}1</t>"
        assert_equal [{"amount" => tiny}], records
      end

      it "is written as the digits of a number smaller than Excel's smallest, a subnormal double" do
        tiny = BigDecimal("1.23456789e-310")
        path = IOStreams.path(file_name).schema(fields: [{name: "amount", type: "number"}])
        path.writer(:hash) { |io| io << {"amount" => tiny} }
        records = []
        path.each(:hash) { |record| records << record }

        refute_match(/<v>1\.2345/, worksheet_xml(File.binread(file_name)))
        assert_equal [{"amount" => tiny}], records
      end

      it "is written as the text of its field when Excel cannot hold the number, as CSV writes it, also without decimals" do
        schema = {fields: [{name: "id", type: "number", groupChar: ","}, {name: "big", type: "integer"}, {name: "tiny"}]}
        path   = IOStreams.path(file_name).schema(schema)
        path.writer(:hash) { |io| io << {"id" => 12_345_678_901_234_567, "big" => 2**70, "tiny" => 1.5e-310} }
        xml = worksheet_xml(File.binread(file_name))

        assert_includes xml, "<t>12,345,678,901,234,567</t>"
        assert_includes xml, "<t>1180591620717411303424</t>"
        assert_includes xml, "<t>1.5e-310</t>"
        refute_includes xml, "<v>1.5e-310</v>"
      end

      it "is written with the decimals of its field when Excel cannot hold the number, as CSV writes it" do
        huge = BigDecimal("1#{'0' * 400}.5")
        path = IOStreams.path(file_name).schema(fields: [{name: "amount", type: "number", decimals: 2}, {name: "id", type: "number", decimals: 2}])
        path.writer(:hash) { |io| io << {"amount" => huge, "id" => 12_345_678_901_234_567} }
        xml = worksheet_xml(File.binread(file_name))

        assert_includes xml, "<t>1#{'0' * 400}.50</t>"
        assert_includes xml, "<t>12345678901234567.00</t>"
      end

      it "is written as the digits of a BigDecimal larger than a double holds, rather than an infinity" do
        huge = BigDecimal("1#{'0' * 400}.5")
        path = IOStreams.path(file_name).schema(fields: [{name: "amount", type: "number"}])
        path.writer(:hash) { |io| io << {"amount" => huge} }
        xml = worksheet_xml(File.binread(file_name))
        records = []
        path.each(:hash) { |record| records << record }

        refute_includes xml, "Infinity"
        assert_includes xml, "<t>1#{'0' * 400}.5</t>"
        assert_equal [{"amount" => huge}], records
      end

      it "is written as its text when Excel cannot hold the number, without a format" do
        path = IOStreams.path(file_name).schema(fields: [{name: "id", type: "number", decimals: 0}])
        path.writer(:hash) { |io| io << {"id" => 12_345_678_901_234_567_890} }

        assert_includes worksheet_xml(File.binread(file_name)), "<t>12345678901234567890</t>"
      end
    end

    describe "auto_format" do
      it "writes text of a number that Excel cannot hold as text, and the CSV time of an offset in UTC" do
        big = "9" * 400
        data = write(auto_format: true) do |io|
          io.write(["#{big}.5", "0012345678901234567890", "1.5", "2026-01-02T09:30:00+02:00", "0.#{'0' * 400}1"].to_csv)
        end

        refute_includes worksheet_xml(data), "Infinity"
        assert_equal [["#{big}.5", "0012345678901234567890", "1.5", "2026-01-02T07:30:00", "0.#{'0' * 400}1"]], read_rows(data)
      end
    end

    describe "sheet_name" do
      it "raises before it opens the output for a name with a control character, or that UTF-8 cannot hold" do
        ["a\u0001b", "a\uFFFEb", "caf\xE9", "caf\xE9".b, "a\x81".dup.force_encoding("Windows-1252"), "ab".dup.force_encoding("UTF-7")].each do |name|
          output = StringIO.new(+"")
          error  = assert_raises(ArgumentError) { write(output, sheet_name: name) { |io| io << "a\n" } }

          assert_match(/Invalid sheet_name .*(control character|the name of the worksheet)/, error.message, name.dump)
          assert_equal "", output.string
        end
      end

      it "counts the characters of a name in another encoding, as UTF-8" do
        ["é" * 31, ("é" * 31).b, ("é" * 31).encode("UTF-16LE")].each do |name|
          data = write(sheet_name: name) { |io| io << "a\n" }

          assert_includes worksheet_xml(data, "xl/workbook.xml").force_encoding(Encoding::UTF_8), %(name="#{'é' * 31}")
        end
      end

      it "writes a name of another encoding as UTF-8" do
        data = write(sheet_name: "Café & <Co>".encode("Windows-1252")) { |io| io << "a\n" }

        assert_includes worksheet_xml(data, "xl/workbook.xml").force_encoding(Encoding::UTF_8), %(name="Café &amp; &lt;Co&gt;")
      end
    end

    describe "a duration" do
      it "writes the ISO 8601 text of a duration field, which reads back, rather than its number of seconds" do
        require "active_support"
        require "active_support/core_ext/integer/time"

        path = IOStreams.path(file_name).schema(fields: [{name: "wait", type: "duration"}])
        path.writer(:hash) do |io|
          io << {"wait" => 1.day}
          io << {"wait" => 90.minutes}
        end
        records = []
        path.each(:hash) { |record| records << record }
        lines = []
        IOStreams.path(file_name).each(:line) { |line| lines << line }

        assert_equal([1.day, 90.minutes], records.map { |record| record["wait"] })
        assert_equal %w[wait P1D PT90M], lines
      end

      it "writes a duration without a duration field, or without a schema, as its ISO 8601 text" do
        require "active_support"
        require "active_support/core_ext/integer/time"

        IOStreams.path(file_name).writer(:hash) { |io| io << {"wait" => 1.day} }
        xml = worksheet_xml(File.binread(file_name))

        assert_includes xml, "<t>P1D</t>"
        IOStreams.path(file_name).schema(fields: [{name: "wait", type: "any"}]).writer(:hash) { |io| io << {"wait" => 2.months} }

        assert_includes worksheet_xml(File.binread(file_name)), "<t>P2M</t>"
      end
    end

    describe "the format of the rows" do
      it "writes each value into its own cell, whatever format the file name names before the extension" do
        path = IOStreams.path(File.join(dir, "report.psv.xlsx"))
        path.writer(:array) do |io|
          io << %w[id name]
          io << [1, "Smith, Jack"]
        end

        # The Integer is a number cell, which reading as CSV text gives as the number that the workbook holds.
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
