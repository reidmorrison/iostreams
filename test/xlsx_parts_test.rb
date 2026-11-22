# frozen_string_literal: true

require_relative "test_helper"
require "zip"

# Reads workbooks whose parts are written by hand, for what spreadsheet applications other than Excel write, and for
# XML that a workbook can hold, which the spreadsheets of the other tests do not.
class XlsxPartsTest < Minitest::Test
  MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  RELS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

  describe IOStreams::Xlsx::Reader do
    let(:dir) { Dir.mktmpdir("iostreams") }

    after { FileUtils.rm_rf(dir) }

    # Returns the name of a workbook of the supplied parts, by their names, with the relationships and the workbook of
    # one worksheet, `xl/worksheets/sheet1.xml`, unless the parts supply their own.
    def workbook(parts)
      parts = {
        "_rels/.rels"                => relationships("officeDocument" => "xl/workbook.xml"),
        "xl/workbook.xml"            => %(<workbook xmlns="#{MAIN}" xmlns:r="#{RELS}"><sheets><sheet name="One" sheetId="1" r:id="rId1"/></sheets></workbook>),
        "xl/_rels/workbook.xml.rels" => relationships({"worksheet" => "worksheets/sheet1.xml"}.merge(parts.delete(:related) || {}))
      }.merge(parts)
      file_name = File.join(dir, "parts.xlsx")
      # A part of nil is left out.
      Zip::OutputStream.open(file_name) { |zip| parts.compact.each { |name, xml| zip.put_next_entry(name) && zip.write(xml) } }
      file_name
    end

    def relationships(targets)
      list = targets.each_with_index.map do |(type, target), index|
        %(<Relationship Id="rId#{index + 1}" Type="#{RELS}/#{type}" Target="#{target}"/>)
      end
      %(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">#{list.join}</Relationships>)
    end

    def sheet(rows)
      %(<?xml version="1.0" encoding="UTF-8"?>\n<worksheet xmlns="#{MAIN}"><sheetData>#{rows}</sheetData></worksheet>)
    end

    def rows(file_name)
      IOStreams::Xlsx::Reader::Rows.new(file_name, file_name).to_a
    end

    def text(file_name)
      IOStreams.path(file_name).read
    end

    it "decodes the entities and character references of text and attributes" do
      name = workbook(
        "xl/worksheets/sheet1.xml" => sheet(%(<row><c r="A1" t="inlineStr"><is><t>R&amp;D &lt;1&gt; &quot;a&quot; &apos;b&apos; &#233;&#x20AC;</t></is></c></row>)),
        "xl/workbook.xml"          => %(<workbook xmlns="#{MAIN}" xmlns:r="#{RELS}"><sheets><sheet name="R&amp;D" sheetId="1" r:id="rId1"/></sheets></workbook>)
      )

      assert_equal [[%(R&D <1> "a" 'b' é€)]], rows(name)
    end

    it "reads a CR LF and a CR as a LF, as XML does, and a character reference of a CR as a CR" do
      name = workbook("xl/worksheets/sheet1.xml" => sheet(%(<row><c r="A1" t="inlineStr"><is><t>a\r\nb\rc&#13;d</t></is></c></row>)))

      assert_equal [["a\nb\nc\rd"]], rows(name)
    end

    it "decodes the characters that Excel escapes, of inline, formula and shared strings" do
      name = workbook(
        related:                   {"sharedStrings" => "sharedStrings.xml"},
        "xl/sharedStrings.xml"     => %(<sst xmlns="#{MAIN}"><si><t>a_x000D_b _x005F_x000D_ _xD800_</t></si></sst>),
        "xl/worksheets/sheet1.xml" => sheet(%(<row><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>c_x0009_d</t></is></c><c r="C1" t="str"><f>A1</f><v>e_x000A_f</v></c></row>))
      )

      assert_equal [["a\rb _x000D_ _xD800_", "c\td", "e\nf"]], rows(name)
    end

    it "joins the runs of rich text, without a phonetic run, of shared and inline strings" do
      name = workbook(
        related:                   {"sharedStrings" => "sharedStrings.xml"},
        "xl/sharedStrings.xml"     => %(<sst xmlns="#{MAIN}"><si><r><t>Text</t></r><r><rPr><b/></rPr><t xml:space="preserve"> 1 </t></r><rPh sb="0" eb="1"><t>ignored</t></rPh></si><si/><si><t/></si></sst>),
        "xl/worksheets/sheet1.xml" => sheet(%(<row><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><r><t>a</t></r><r><t>b</t></r><rPh><t>x</t></rPh></is></c><c r="C1" t="s"><v>1</v></c><c r="D1" t="s"><v>2</v></c><c r="E1" t="inlineStr"><is><t/></is></c><c r="F1" t="inlineStr"><is><t>f</t></is></c></row>))
      )

      assert_equal [["Text 1 ", "ab", "", "", nil, "f"]], rows(name)
    end

    it "reads elements and attributes with a namespace prefix, single quotes and white space within tags" do
      sheet = %(<x:worksheet xmlns:x="#{MAIN}"><x:sheetData>\n  <x:row r='1'>\n    <x:c\n r = 'A1'\tt="inlineStr" ><x:is><x:t>a</x:t></x:is></x:c>\n    <x:c r="B1"><x:v>2</x:v></x:c>\n  </x:row>\n</x:sheetData></x:worksheet>)

      assert_equal [["a", 2.0]], rows(workbook("xl/worksheets/sheet1.xml" => sheet))
    end

    it "skips comments, processing instructions and extension lists, and reads CDATA as text" do
      name = workbook("xl/worksheets/sheet1.xml" => sheet(%(<!-- <row><c r="A1"><v>9</v></c></row> --><?pi <row>?><row><c r="A1" t="inlineStr"><is><t><![CDATA[<b> & a\r\nb]]></t></is></c><extLst><ext><x14:row xmlns:x14="x"><c r="B1"><v>1</v></c></x14:row></ext></extLst></row>)))

      assert_equal [["<b> & a\nb"]], rows(name)
    end

    it "places a cell without a reference after the one before it, and a reference without case" do
      name = workbook("xl/worksheets/sheet1.xml" => sheet(%(<row><c><v>1</v></c><c><v>2</v></c><c r="d1"><v>4</v></c><c><v>5</v></c></row><row><c r="AA2"><v>27</v></c></row>)))
      rows = rows(name)

      assert_equal [1.0, 2.0, nil, 4.0, 5.0], rows[0]
      assert_equal 26, rows[1].index(27.0)
    end

    it "reads an empty row, and a row of cells without values, as empty, up to the last cell otherwise" do
      name = workbook("xl/worksheets/sheet1.xml" => sheet(%(<row r="1"/><row r="2"><c r="A2" s="0"/><c r="B2" s="0"/></row><row r="4"><c r="B4"><v>1</v></c><c r="D4" s="0"/></row>)))

      assert_equal [[], [], [nil, 1.0, nil, nil]], rows(name)
    end

    it "reads booleans, errors, numbers and formulas by their cell types" do
      name = workbook("xl/worksheets/sheet1.xml" => sheet(%(<row><c r="A1" t="b"><v>1</v></c><c r="B1" t="b"><v>0</v></c><c r="C1" t="e"><v>#N/A</v></c><c r="D1" t="n"><v>1e+20</v></c><c r="E1"><f>1+1</f><v>2</v></c></row>)))

      assert_equal [[true, false, nil, 1e20, 2.0]], rows(name)
      assert_equal "true,false,#N/A,100000000000000000000,2\n", text(name)
    end

    it "reads the date system of the workbook, rather than that of an extension of it" do
      name = workbook(
        related:                   {"styles" => "styles.xml"},
        "xl/workbook.xml"          => %(<workbook xmlns="#{MAIN}" xmlns:r="#{RELS}"><workbookPr date1904="true"/><sheets><sheet name="One" sheetId="1" r:id="rId1"/></sheets><extLst><ext><x15:workbookPr xmlns:x15="x" chartTrackingRefBase="1"/></ext></extLst></workbook>),
        "xl/styles.xml"            => %(<styleSheet xmlns="#{MAIN}"><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>),
        "xl/worksheets/sheet1.xml" => sheet(%(<row><c r="A1" s="1"><v>43708</v></c></row>))
      )

      assert_equal [[Date.new(2023, 9, 1)]], rows(name)
    end

    it "reads a date before 1900-03-01 as the date that Excel shows, though it counts 1900-02-29" do
      cells = [0, 1, 59, 60, 61, 0.5, 60.5].each_with_index.map { |day, i| %(<c r="#{(65 + i).chr}1" s="#{i < 5 ? 1 : 2}"><v>#{day}</v></c>) }
      name  = workbook(
        related:                   {"styles" => "styles.xml"},
        "xl/styles.xml"            => %(<styleSheet xmlns="#{MAIN}"><cellXfs count="3"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="22"/></cellXfs></styleSheet>),
        "xl/worksheets/sheet1.xml" => sheet(%(<row>#{cells.join}</row>))
      )

      assert_equal [[Date.new(1899, 12, 31), Date.new(1900, 1, 1), Date.new(1900, 2, 28), Date.new(1900, 2, 28),
                     Date.new(1900, 3, 1), Time.utc(1899, 12, 31, 12), Time.utc(1900, 2, 28, 12)]], rows(name)
      lines = []
      IOStreams.path(name).each(:line) { |line| lines << line }

      assert_equal ["1899-12-31,1900-01-01,1900-02-28,1900-02-28,1900-03-01,1899-12-31T12:00:00,1900-02-28T12:00:00"], lines
    end

    it "reads a date of the 1904 date system without a leap day" do
      name = workbook(
        related:                   {"styles" => "styles.xml"},
        "xl/workbook.xml"          => %(<workbook xmlns="#{MAIN}" xmlns:r="#{RELS}"><workbookPr date1904="1"/><sheets><sheet name="One" sheetId="1" r:id="rId1"/></sheets></workbook>),
        "xl/styles.xml"            => %(<styleSheet xmlns="#{MAIN}"><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>),
        "xl/worksheets/sheet1.xml" => sheet(%(<row><c r="A1" s="1"><v>0</v></c><c r="B1" s="1"><v>59</v></c><c r="C1" s="1"><v>2957003</v></c><c r="D1" s="1"><v>2957004</v></c></row>))
      )

      assert_equal [[Date.new(1904, 1, 1), Date.new(1904, 2, 29), Date.new(9999, 12, 31), 2_957_004.0]], rows(name)
    end

    it "reads the number of a date cell of a tiny exponent or many digits at once, as the double that Excel holds" do
      name = workbook(
        related:                   {"styles" => "styles.xml"},
        "xl/styles.xml"            => %(<styleSheet xmlns="#{MAIN}"><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="22"/></cellXfs></styleSheet>),
        "xl/worksheets/sheet1.xml" => sheet(%(<row><c r="A1" s="1"><v>1e-100000000</v></c><c r="B1" s="1"><v>45000.#{'0' * 100_000}1</v></c></row>))
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_equal [[Time.utc(1899, 12, 31), Time.utc(2023, 3, 15)]], rows(name)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    end

    it "reads the custom number formats of the styles, and not those of differential formats" do
      name = workbook(
        related:                   {"styles" => "styles.xml"},
        "xl/styles.xml"            => %(<styleSheet xmlns="#{MAIN}"><numFmts><numFmt numFmtId="164" formatCode="yyyy&quot;-&quot;mm"/></numFmts><cellXfs><xf numFmtId="0"/><xf numFmtId="164"/><xf numFmtId="165"/></cellXfs><dxfs><dxf><numFmt numFmtId="165" formatCode="yyyy"/></dxf></dxfs></styleSheet>),
        "xl/worksheets/sheet1.xml" => sheet(%(<row><c r="A1" s="1"><v>45000</v></c><c r="B1" s="2"><v>45000</v></c></row>))
      )

      assert_equal [[Date.new(2023, 3, 15), 45_000.0]], rows(name)
    end

    it "finds the parts by their relationships, without case, relative or absolute, of Strict OOXML too" do
      strict = "http://purl.oclc.org/ooxml/officeDocument/relationships"
      name   = workbook(
        "_rels/.rels"                => %(<Relationships xmlns="x"><Relationship Id="r1" Type="#{strict}/officeDocument" Target="/Book/Main.xml"/></Relationships>),
        "Book/Main.xml"              => %(<workbook xmlns="http://purl.oclc.org/ooxml/spreadsheetml/main" xmlns:r="#{strict}"><sheets><sheet name="Chart" sheetId="2" r:id="c"/><sheet name="One" sheetId="1" r:id="s"/></sheets></workbook>),
        "book/_rels/main.xml.rels"   => %(<Relationships xmlns="x"><Relationship Id="c" Type="#{strict}/chartsheet" Target="charts/c.xml"/><Relationship Id="s" Type="#{strict}/worksheet" Target="../Sheets/S.xml"/><Relationship Id="t" Type="#{strict}/sharedStrings" Target="/book/strings.xml"/><Relationship Id="h" Type="#{strict}/hyperlink" Target="http://example.com/a.xml" TargetMode="External"/></Relationships>),
        "BOOK/STRINGS.XML"           => %(<sst><si><t>shared</t></si></sst>),
        "sheets/s.xml"               => sheet(%(<row><c r="A1" t="s"><v>0</v></c></row>)),
        "xl/workbook.xml"            => "",
        "xl/_rels/workbook.xml.rels" => ""
      )

      assert_equal [["shared"]], rows(name)
    end

    it "reads text that spans the chunks of a part, with entities and line breaks at their ends" do
      chunk = IOStreams::Xlsx::XmlScanner::CHUNK_SIZE
      texts = (1..40).map { |n| "#{'x' * (chunk - 3 + n)}&amp;\r\n_x0009_" }
      cells = texts.each_with_index.map { |t, i| %(<c r="A#{i + 1}" t="inlineStr"><is><t>#{t}</t></is></c>) }
      name  = workbook("xl/worksheets/sheet1.xml" => sheet(cells.map { |c| "<row>#{c}</row>" }.join))
      expected = (1..40).map { |n| ["#{'x' * (chunk - 3 + n)}&\n\t"] }

      assert_equal expected, rows(name)
    end

    it "reads text whose characters of more than one byte span the chunks of a part, with entities and line breaks" do
      chunk = IOStreams::Xlsx::XmlScanner::CHUNK_SIZE
      texts = (1..12).map { |n| "#{'x' * (chunk - 40 + n)}é日\u{1F600}\r\né&amp;日\r\n\u{1F600}" }
      cells = texts.each_with_index.map { |t, i| %(<c r="A#{i + 1}" t="inlineStr"><is><t>#{t}</t></is></c>) }
      # Each cell in a row of its own, which places each text at another offset of its chunk.
      name  = workbook("xl/worksheets/sheet1.xml" => sheet(cells.map { |c| "<row>#{c}</row>" }.join))
      expected = (1..12).map { |n| ["#{'x' * (chunk - 40 + n)}é日\u{1F600}\né&日\n\u{1F600}"] }

      assert_equal expected, rows(name)
    end

    it "reads a workbook without relationships of its own by the parts that Excel names, in the folder of the workbook" do
      name = workbook(
        "_rels/.rels"                => relationships("officeDocument" => "book/workbook.xml"),
        "xl/workbook.xml"            => nil,
        "xl/_rels/workbook.xml.rels" => nil,
        "book/workbook.xml"          => %(<workbook xmlns="#{MAIN}"><sheets><sheet name="One" sheetId="1"/></sheets></workbook>),
        "book/sharedStrings.xml"     => %(<sst xmlns="#{MAIN}"><si><t>shared</t></si></sst>),
        "book/worksheets/sheet1.xml" => sheet(%(<row><c r="A1" t="s"><v>0</v></c></row>))
      )

      assert_equal [["shared"]], rows(name)
    end

    it "reads text after an & that starts no reference as it is, a chunk at a time" do
      chunk = IOStreams::Xlsx::XmlScanner::CHUNK_SIZE
      text  = "R&D #{'a' * (chunk * 3)} &amp; &#x41;"
      name  = workbook("xl/worksheets/sheet1.xml" => sheet(%(<row><c r="A1" t="inlineStr"><is><t>#{text}</t></is></c></row>)))

      assert_equal [["R&D #{'a' * (chunk * 3)} & A"]], rows(name)
    end

    it "reads cells whose tags do not nest, without the text after them" do
      name = workbook(
        "xl/sharedStrings.xml"     => %(<sst xmlns="#{MAIN}"><si><t>a</si><si><t>b</t></si></sst>),
        "xl/worksheets/sheet1.xml" => sheet(%(<row r="1"><c r="A1"><v>1</c>x</row><row r="2"><c r="A2"><v>2</v></row></c><row r="3"><c r="A3" t="s"><v>1</v></c></row>)),
        related:                   {"sharedStrings" => "sharedStrings.xml"}
      )

      assert_equal [[1.0], [2.0], ["b"]], rows(name)
    end

    it "reads a part that starts with a UTF-8 byte order mark" do
      name = workbook("xl/worksheets/sheet1.xml" => "\xEF\xBB\xBF".b + sheet(%(<row><c r="A1"><v>1</v></c></row>)))

      assert_equal [[1.0]], rows(name)
    end

    describe "raises Corrupt" do
      def assert_corrupt(name, message)
        error = assert_raises(IOStreams::Errors::Corrupt) { rows(name) }
        assert_includes error.message, message
        assert_raises(IOStreams::Errors::Corrupt) { text(name) }
      end

      it "for a document type declaration, rather than expand its entities" do
        xml = "<!DOCTYPE worksheet [<!ENTITY a \"aaaaaaaaaa\"><!ENTITY b \"&a;&a;&a;\">]>#{sheet(%(<row><c r="A1" t="inlineStr"><is><t>&b;</t></is></c></row>))}"

        assert_corrupt workbook("xl/worksheets/sheet1.xml" => xml), "document type declaration"
      end

      it "for a tag that is not well formed" do
        assert_corrupt workbook("xl/worksheets/sheet1.xml" => sheet(%(<row><c r="A1></row>))), "not well formed"
      end

      it "for a part in UTF-16" do
        assert_corrupt workbook("xl/worksheets/sheet1.xml" => "\xFF\xFE".b + sheet("").encode("UTF-16LE").b), "UTF-16"
      end

      it "for a workbook without a worksheet" do
        name = workbook("xl/workbook.xml" => %(<workbook xmlns="#{MAIN}"><sheets/></workbook>))

        assert_corrupt name, "has no worksheet"
      end

      it "for text that is not UTF-8" do
        xml = sheet(%(<row><c r="A1" t="inlineStr"><is><t>a\xFFb\r\nc &amp;</t></is></c></row>)).b

        assert_corrupt workbook("xl/worksheets/sheet1.xml" => xml), %(bytes that are not UTF-8, "\\xFF")
      end

      it "for a cell after Excel's last column, rather than hold a row of that many cells" do
        name = workbook("xl/worksheets/sheet1.xml" => sheet(%(<row><c r="XFD1"><v>1</v></c><c r="ZZZZZZZ1"><v>2</v></c></row>)))

        assert_corrupt name, %(the cell reference "ZZZZZZZ1", after Excel's last column, XFD)
        long = workbook("xl/worksheets/sheet1.xml" => sheet(%(<row><c r="#{'Z' * 1000}1"><v>2</v></c></row>)))
        error = assert_raises(IOStreams::Errors::Corrupt) { rows(long) }
        assert_includes error.message, %("#{'Z' * 32}...")
        refute_includes error.message, "Z" * 33
      end

      it "for a zip file without a workbook" do
        name = workbook("_rels/.rels" => relationships("officeDocument" => "xl/missing.xml"))

        assert_corrupt name, %(does not contain the part "xl/missing.xml")
      end
    end
  end
end
