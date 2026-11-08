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

      it "writes text in another encoding as UTF-8, such as that of #puts, which writes each object in its own encoding" do
        data = write { |io| io.puts("name", "caf\xE9".b.force_encoding("Windows-1252"), "a,b".encode("UTF-16LE")) }

        assert_equal [["name"], ["caf\u{e9}"], %w[a b]], read_rows(data)
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

      it "writes a date and time before 1899-12-31, whose number would be that of a time of day, as its text" do
        path = IOStreams.path(file_name).schema(schema.merge(fields: schema[:fields] + [{name: "any", type: "any"}]))
        path.option(:xlsx, auto_format: true).writer(:hash) do |io|
          io << {"starts" => Time.utc(2000, 1, 1, 12), "ny" => nil, "at" => Time.utc(1899, 12, 30, 12),
                 "any" => "1899-12-30T06:00:00"}
          io << {"starts" => nil, "ny" => nil, "at" => Time.utc(1899, 12, 31), "any" => Time.utc(1899, 12, 29, 6)}
        end
        xml = worksheet_xml(File.binread(file_name))

        assert_match(%r{<c r="A2" s="3"><v>0\.5</v>}, xml)
        assert_includes xml, "<t>1899-12-30T12:00:00</t>"
        assert_includes xml, "<t>1899-12-30T06:00:00</t>"
        assert_includes xml, "<t>1899-12-29T06:00:00</t>"
        assert_match(%r{<c r="C3" s="2"><v>1\.0</v>}, xml)
        records = []
        path.each(:hash) { |record| records << record.slice("at") }

        assert_equal [{"at" => Time.utc(1899, 12, 30, 12)}, {"at" => Time.utc(1899, 12, 31)}], records
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

      it "writes a workbook without a time of day with the workbook of xlsxtream, whose styles it leaves as they are" do
        IOStreams.path(file_name).schema(fields: [{name: "at", type: "datetime"}]).writer(:array) do |io|
          io << [Time.utc(2026, 7, 1, 9, 30)]
        end

        assert_includes worksheet_xml(File.binread(file_name), "xl/styles.xml"), '<cellXfs count="3">'
        refute_includes worksheet_xml(File.binread(file_name), "xl/styles.xml"), 'numFmtId="21"'
      end

      describe "a version of xlsxtream whose styles it does not know" do
        # The gem that each test changes, which IOStreams loads only once it writes a spreadsheet, and the workbook,
        # which reads xlsxtream's style of a date and time, `Row::TIME_STYLE`, and checks the gem, as its class is
        # loaded, so that it does so before a test changes the gem.
        before do
          require "xlsxtream"
          IOStreams::Xlsx::Workbook
        end

        # Checks the version of xlsxtream again within the block, which the workbook otherwise checks once, as it is
        # loaded.
        def recheck
          checked = IOStreams::Xlsx::Workbook.instance_variable_get(:@problem)
          IOStreams::Xlsx::Workbook.instance_variable_set(:@problem, IOStreams::Xlsx::Workbook.send(:problem))
          yield
        ensure
          IOStreams::Xlsx::Workbook.instance_variable_set(:@problem, checked)
        end

        # Writes a time of day to the existing file, which raises before it is opened, so that the file is untouched.
        def assert_raises_before_writing(pattern)
          File.write(file_name, "existing")
          error = assert_raises(IOStreams::Errors::Error) do
            IOStreams.path(file_name).schema(schema).writer(:hash) { |io| io << {"starts" => Time.utc(2000, 1, 1, 9, 30)} }
          end

          assert_match(pattern, error.message)
          assert_equal "existing", File.read(file_name)
        end

        it "raises before it writes for a style of a date and time other than 2" do
          style = ::Xlsxtream::Row::TIME_STYLE
          ::Xlsxtream::Row.send(:remove_const, :TIME_STYLE)
          ::Xlsxtream::Row.const_set(:TIME_STYLE, 9)

          recheck { assert_raises_before_writing(/xlsxtream .* no longer writes the styles of its cells/) }
        ensure
          ::Xlsxtream::Row.send(:remove_const, :TIME_STYLE)
          ::Xlsxtream::Row.const_set(:TIME_STYLE, style)
        end

        it "raises before it writes for styles of other cells" do
          ::Xlsxtream::Workbook.alias_method(:iostreams_test_write_styles, :write_styles)
          ::Xlsxtream::Workbook.define_method(:write_styles) do
            @writer << %(<styleSheet><cellXfs count="4"><xf/></cellXfs></styleSheet>)
          end

          recheck { assert_raises_before_writing(/no longer writes the styles of its cells/) }
        ensure
          ::Xlsxtream::Workbook.alias_method(:write_styles, :iostreams_test_write_styles)
          ::Xlsxtream::Workbook.send(:remove_method, :iostreams_test_write_styles)
          ::Xlsxtream::Workbook.send(:private, :write_styles)
        end

        it "raises before it writes without the styles that xlsxtream writes, or its writer" do
          ::Xlsxtream::Workbook.alias_method(:iostreams_test_write_styles, :write_styles)
          ::Xlsxtream::Workbook.send(:remove_method, :write_styles)

          recheck { assert_raises_before_writing(/no longer writes the styles of its cells/) }
          # xlsxtream 2.x names its writer @io.
          ::Xlsxtream::Workbook.define_method(:write_styles) { @io << %(<cellXfs count="3"></cellXfs>) }

          recheck { assert_raises_before_writing(/no longer writes the styles of its cells/) }
        ensure
          ::Xlsxtream::Workbook.alias_method(:write_styles, :iostreams_test_write_styles)
          ::Xlsxtream::Workbook.send(:remove_method, :iostreams_test_write_styles)
          ::Xlsxtream::Workbook.send(:private, :write_styles)
        end

        it "raises before it writes for a version other than 3" do
          version = ::Xlsxtream::VERSION
          ::Xlsxtream.send(:remove_const, :VERSION)
          ::Xlsxtream.const_set(:VERSION, "2.4.0")

          recheck { assert_raises_before_writing(/xlsxtream 2\.4\.0 is not a version .* xlsxtream >= 3\.0, < 4/) }
        ensure
          ::Xlsxtream.send(:remove_const, :VERSION)
          ::Xlsxtream.const_set(:VERSION, version)
        end

        it "still writes a workbook without a time of day" do
          version = ::Xlsxtream::VERSION
          ::Xlsxtream.send(:remove_const, :VERSION)
          ::Xlsxtream.const_set(:VERSION, "2.4.0")
          recheck do
            IOStreams.path(file_name).schema(fields: [{name: "at", type: "datetime"}]).writer(:array) do |io|
              io << [Time.utc(2026, 7, 1, 9, 30)]
            end
          end

          records = []
          IOStreams.path(file_name).each(:hash) { |record| records << record }

          assert_equal [{"at" => Time.utc(2026, 7, 1, 9, 30)}], records
        ensure
          ::Xlsxtream.send(:remove_const, :VERSION)
          ::Xlsxtream.const_set(:VERSION, version)
        end
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
