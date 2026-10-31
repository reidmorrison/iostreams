# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "json"

class XlsxRowsTest < Minitest::Test
  describe "the typed cells of a spreadsheet" do
    let(:dir) { Dir.mktmpdir("iostreams") }
    let(:file_name) { File.join(dir, "orders.xlsx") }
    let(:at) { Time.utc(2026, 10, 25, 9, 30) }

    after { FileUtils.rm_rf(dir) }

    # Writes a workbook with xlsxtream itself, so that its cells are typed as Excel types them.
    def workbook(*rows)
      require "xlsxtream"
      Xlsxtream::Workbook.open(file_name) do |book|
        book.write_worksheet("Sheet1") do |sheet|
          rows.each { |row| sheet << row }
        end
      end
    end

    # Returns [Array] the rows or records read.
    def read(stream = IOStreams.path(file_name), mode = :hash, **)
      rows = []
      stream.each(mode, **) { |row| rows << row }
      rows
    end

    describe "reading" do
      before do
        workbook(
          %w[id amount ordered_at shipped_on zip paid notes ratio],
          [1001, 12.5, at, Date.new(2026, 10, 25), "01234", true, nil, 0.1 + 0.2]
        )
      end

      it "yields each cell as Excel typed it: a Float for every number, a Date, a Time in UTC, text and booleans" do
        assert_equal [{"id" => 1001.0, "amount" => 12.5, "ordered_at" => at, "shipped_on" => Date.new(2026, 10, 25),
                       "zip" => "01234", "paid" => true, "notes" => nil, "ratio" => 0.30000000000000004}], read
        assert_instance_of Date, read.first["shipped_on"]
        assert_predicate read.first["ordered_at"], :utc?
      end

      it "yields a header row and the typed values of each row with each(:array)" do
        rows = read(IOStreams.path(file_name), :array)

        assert_instance_of IOStreams::Row::HeaderRow, rows.first
        assert_equal [1001.0, 12.5, at, Date.new(2026, 10, 25), "01234", true, nil, 0.30000000000000004], rows.last
      end

      it "still reads the lines and bytes of the spreadsheet as CSV text" do
        lines = read(IOStreams.path(file_name), :line)

        assert_equal "1001.0,12.5,2026-10-25T09:30:00Z,2026-10-25T00:00:00Z,01234,true,,0.30000000000000004", lines.last
        assert_equal "#{lines.join("\n")}\n", IOStreams.path(file_name).read
      end

      it "reads its lines as the :text format, which holds the CSV of each row as it is" do
        assert_equal ["id,amount,ordered_at,shipped_on,zip,paid,notes,ratio"], read(IOStreams.path(file_name).format(:text), :array).first
      end

      it "converts each cell to the type of its field of a contract, a whole Float to an integer" do
        contract = IOStreams::Contract.new(
          fieldsMatch: "partial",
          fields:      [{name: "id", type: "integer"}, {name: "shipped_on", type: "date"}, {name: "zip", type: "string"}]
        )

        assert_equal [{"id" => 1001, "shipped_on" => Date.new(2026, 10, 25), "zip" => "01234"}],
                     read(IOStreams.path(file_name).as(contract))
      end

      it "reads the digits that Excel displays of a number field, rather than those of the Float that it holds" do
        contract = IOStreams::Contract.new(fieldsMatch: "partial", fields: [{name: "ratio", type: "number"}])

        assert_equal BigDecimal("0.3"), read(IOStreams.path(file_name).as(contract)).first["ratio"]
      end

      it "declares the names of its columns, whose cells each have their own type" do
        assert_equal(%w[any], IOStreams.path(file_name).infer_schema.fields.map(&:type).uniq)
      end

      it "drafts the types of its columns from the types of their cells" do
        types = IOStreams.path(file_name).infer_schema(sample: :all).fields.to_h { |field| [field.name, field.type] }

        assert_equal({"id" => "integer", "amount" => "number", "ordered_at" => "datetime", "shipped_on" => "date",
                      "zip" => "string", "paid" => "boolean", "notes" => "any", "ratio" => "number"}, types)
      end

      it "reads slices of its typed rows, whose dates and times JSON holds as ISO 8601 text" do
        slices = []
        IOStreams.path(file_name).each(:slice, size: 10) { |slice| slices << slice }

        assert_equal :array, slices.first.format
        assert_equal [1001.0, 12.5, "2026-10-25T09:30:00Z", "2026-10-25", "01234", true, nil, 0.30000000000000004],
                     slices.first.to_h["rows"].first
      end

      it "raises for a delimiter of the rows read, which are cells rather than lines" do
        assert_raises(ArgumentError) { read(IOStreams.path(file_name), :hash, delimiter: "\n") }
      end

      it "raises for an encoding of the rows read, which are cells rather than text, as their lines take it" do
        error = assert_raises(ArgumentError) { read(IOStreams.path(file_name).encoding("ISO-8859-1"), :hash) }

        assert_includes error.message, "#encoding cannot be used with the rows"
        assert_equal 2, read(IOStreams.path(file_name).encoding("UTF-8"), :line).size
      end
    end

    describe "the digits that Excel displays" do
      it "are read once the header row places the columns, after a blank row before it" do
        workbook([], %w[ratio], [0.1 + 0.2])

        assert_equal [{"ratio" => BigDecimal("0.3")}], read(IOStreams.path(file_name).as(fields: [{name: "ratio", type: "number"}]))
      end

      it "are read from the first row of a file without a header row, by the positions of its fields" do
        workbook([0.1 + 0.2, "x"])
        schema = {header: false, fields: [{name: "ratio", type: "number"}, {name: "note"}]}

        assert_equal [{"ratio" => BigDecimal("0.3"), "note" => "x"}], read(IOStreams.path(file_name).schema(schema))
      end
    end

    describe "cells of each kind" do
      it "reads an error cell and an empty cell as nil, and a formula as its cached value" do
        IOStreams.path(file_name).writer(:array) { |io| io << %w[a b] }
        # A worksheet whose cells are an error, an empty value, and a formula, as Excel writes them.
        sheet = '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' \
                '<row r="1"><c r="A1" t="inlineStr"><is><t>a</t></is></c><c r="B1" t="inlineStr"><is><t>b</t></is></c>' \
                '<c r="C1" t="inlineStr"><is><t>c</t></is></c></row>' \
                '<row r="2"><c r="A2" t="e"><v>#N/A</v></c><c r="B2" t="str"><f>CONCAT("x","y")</f><v>xy</v></c>' \
                "<c r=\"C2\"><f>1+1</f><v>2</v></c></row></sheetData></worksheet>"
        replace_sheet(sheet)

        assert_equal [{"a" => nil, "b" => "xy", "c" => 2.0}], read
      end

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

      # Replaces the first worksheet of the workbook with the supplied XML.
      def replace_sheet(xml)
        require "zip"
        Zip::File.open(file_name) do |zip|
          zip.get_output_stream("xl/worksheets/sheet1.xml") { |io| io << xml }
        end
      end
    end

    describe "writing" do
      let(:contract) do
        IOStreams::Contract.new(
          fields: [
            {name: "id", type: "integer"},
            {name: "amount", type: "number", decimals: 2},
            {name: "ordered_at", type: "datetime"},
            {name: "shipped_on", type: "date"},
            {name: "zip", type: "string"},
            {name: "paid", type: "boolean"}
          ]
        )
      end

      let(:record) do
        {"id" => 1001, "amount" => BigDecimal("12.5"), "ordered_at" => at, "shipped_on" => Date.new(2026, 10, 25),
         "zip" => "01234", "paid" => true}
      end

      it "writes each field as its type, which reads back as Excel types it" do
        IOStreams.path(file_name).as(contract).writer(:hash) { |io| io << record }

        assert_equal [{"id" => 1001.0, "amount" => 12.5, "ordered_at" => at, "shipped_on" => Date.new(2026, 10, 25),
                       "zip" => "01234", "paid" => true}], read
        assert_equal [record], read(IOStreams.path(file_name).as(contract))
      end

      it "writes text of a string field as text with auto_format, which applies only to columns of no known type" do
        schema = {fields: [{name: "zip", type: "string"}, {name: "code"}]}
        IOStreams.path(file_name).option(:xlsx, auto_format: true).as(schema).writer(:hash) do |io|
          io << {"zip" => "01234", "code" => "01234"}
        end

        assert_equal [{"zip" => "01234", "code" => 1234.0}], read
      end

      it "writes the values of a file without a schema as their types" do
        IOStreams.path(file_name).writer(:array) do |io|
          io << %w[a b c d]
          io << [1, Date.new(2026, 1, 2), "x", {"k" => 1}]
        end

        assert_equal [{"a" => 1.0, "b" => Date.new(2026, 1, 2), "c" => "x", "d" => '{"k":1}'}], read
      end

      it "writes a time in UTC, so that it reads back as the same instant" do
        IOStreams.path(file_name).writer(:array) do |io|
          io << %w[at]
          io << [Time.new(2026, 1, 1, 10, 0, 0, "-05:00")]
        end

        assert_equal [{"at" => Time.utc(2026, 1, 1, 15)}], read
      end

      it "writes a whole number of more digits than Excel keeps, NaN and an infinity as text, which a field reads back" do
        IOStreams.path(file_name).writer(:array) do |io|
          io << %w[id big nan inf]
          io << [1, 12_345_678_901_234_567_890, Float::NAN, -Float::INFINITY]
        end
        contract = IOStreams::Contract.new(
          fields: [{name: "id", type: "integer"}, {name: "big", type: "integer"},
                   {name: "nan", type: "number", floatNumber: true}, {name: "inf", type: "number", floatNumber: true}]
        )

        assert_equal [{"id" => 1.0, "big" => "12345678901234567890", "nan" => "NaN", "inf" => "-INF"}], read
        record = read(IOStreams.path(file_name).as(contract)).first

        assert_equal [1, 12_345_678_901_234_567_890, -Float::INFINITY], record.values_at("id", "big", "inf")
        assert_predicate record["nan"], :nan?
      end

      it "keeps the text of a string field as text past a field that only holds the place of a column" do
        schema = {fields: [{name: "filler", skip: true}, {name: "zip", type: "string"}, {name: "code"}]}
        IOStreams.path(file_name).option(:xlsx, auto_format: true).schema(schema).writer(:hash) do |io|
          io << {"zip" => "01234", "code" => "01234"}
        end

        assert_equal [{"filler" => nil, "zip" => "01234", "code" => 1234.0}], read
      end

      it "writes text of a time without seconds as a time with auto_format, as the lines do" do
        IOStreams.path(file_name).option(:xlsx, auto_format: true).writer(:array) do |io|
          io << %w[at]
          io << ["2026-10-09T10:00"]
        end

        assert_equal [{"at" => Time.utc(2026, 10, 9, 10)}], read
      end

      it "still writes lines of CSV text as text" do
        IOStreams.path(file_name).writer(:line) { |io| io << "a,b" << "1,2" }

        assert_equal [{"a" => "1", "b" => "2"}], read
      end
    end
  end
end
