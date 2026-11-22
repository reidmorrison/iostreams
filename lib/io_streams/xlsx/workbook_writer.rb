# frozen_string_literal: true

module IOStreams
  module Xlsx
    # Writes a workbook with one worksheet to an output stream, as a zip file of its parts, streamed with `zip_kit`
    # without a temp file, even to an output that cannot seek, such as a pipe to `gpg`: the worksheet first, as its rows
    # are written, see `IOStreams::Xlsx::WorksheetWriter`, then, once it is closed, the parts that describe it, which
    # the Open Packaging Conventions require: the workbook, its styles, see `IOStreams::Xlsx::CellStyles`, its shared
    # strings, if any, see `IOStreams::Xlsx::SharedStringTable`, the relationships between them, and the content type
    # of each.
    class WorkbookWriter
      # The parts of the workbook, by their names within it.
      WORKSHEET_PART = "xl/worksheets/sheet1.xml"
      WORKBOOK_PART  = "xl/workbook.xml"

      # How the workbook numbers its days: the 1900 date system, of Excel for Windows.
      DATE_SYSTEM = DateSystem::SYSTEM_1900

      XML_DECLARATION = %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>)

      RELATIONSHIPS  = "http://schemas.openxmlformats.org/package/2006/relationships"
      RELATIONSHIP   = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
      SPREADSHEET_ML = "application/vnd.openxmlformats-officedocument.spreadsheetml"

      # The relationships of the package, which name its main part, the workbook.
      ROOT_RELATIONSHIPS = "#{XML_DECLARATION}<Relationships xmlns=\"#{RELATIONSHIPS}\">" \
                           "<Relationship Id=\"rId1\" Type=\"#{RELATIONSHIP}/officeDocument\" " \
                           "Target=\"#{WORKBOOK_PART}\"/></Relationships>".freeze

      # Returns [IOStreams::Xlsx::WorksheetWriter] the worksheet, which receives the rows.
      attr_reader :worksheet

      # Parameters
      #   output_stream: [IO]
      #     Receives the workbook, which it leaves open.
      #
      #   sheet_name: [String]
      #     The name of the worksheet, which `IOStreams::Xlsx::Writer.check` checks.
      #
      #   use_shared_strings: [true|false]
      #     Whether to write the text of the cells once each in the shared strings of the workbook, rather than within
      #     each cell.
      def initialize(output_stream, sheet_name:, use_shared_strings: false)
        @sheet_name     = sheet_name
        @shared_strings = SharedStringTable.new if use_shared_strings
        @styles         = CellStyles.new
        @zip            = ZipKit::Streamer.new(output_stream)
        @part           = @zip.write_deflated_file(WORKSHEET_PART)
        @worksheet      = WorksheetWriter.new(@part, styles: @styles, shared_strings: @shared_strings,
                                                     date_system: DATE_SYSTEM)
      end

      # Ends the worksheet, writes the other parts, and ends the zip file, without closing the output stream.
      def close
        @worksheet.close
        @part.close
        @part = nil
        write_part(WORKBOOK_PART, workbook)
        write_part(CellStyles::PART, @styles.xml)
        write_part(SharedStringTable::PART) { |io| @shared_strings.write(io) } if shared_strings?
        write_part("xl/_rels/workbook.xml.rels", workbook_relationships)
        write_part("_rels/.rels", ROOT_RELATIONSHIPS)
        write_part("[Content_Types].xml", content_types)
        @zip.close
      end

      # Releases what the part being written holds, after a failure, leaving the output that is not a workbook.
      def abort
        @part&.release_resources_on_failure!
      end

      private

      def shared_strings?
        @shared_strings && !@shared_strings.empty?
      end

      def write_part(name, xml = nil, &block)
        @zip.write_deflated_file(name) { |io| xml ? io << xml : block.call(io) }
      end

      def workbook
        name = Text.utf8(@sheet_name, place: "the name of the worksheet").encode(xml: :attr)
        "#{XML_DECLARATION}<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" " \
          "xmlns:r=\"#{RELATIONSHIP}\"><workbookPr date1904=\"#{DATE_SYSTEM.date1904?}\"/><sheets>" \
          "<sheet name=#{name} sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
      end

      def workbook_relationships
        xml = "#{XML_DECLARATION}<Relationships xmlns=\"#{RELATIONSHIPS}\">" \
              "<Relationship Id=\"rId1\" Type=\"#{RELATIONSHIP}/worksheet\" Target=\"worksheets/sheet1.xml\"/>" \
              "<Relationship Id=\"rId2\" Type=\"#{RELATIONSHIP}/styles\" Target=\"styles.xml\"/>"
        if shared_strings?
          xml << "<Relationship Id=\"rId3\" Type=\"#{RELATIONSHIP}/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        end
        xml << "</Relationships>"
      end

      def content_types
        xml = "#{XML_DECLARATION}<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">" \
              "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" \
              "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>" \
              "<Override PartName=\"/#{WORKBOOK_PART}\" ContentType=\"#{SPREADSHEET_ML}.sheet.main+xml\"/>" \
              "<Override PartName=\"/#{CellStyles::PART}\" ContentType=\"#{SPREADSHEET_ML}.styles+xml\"/>" \
              "<Override PartName=\"/#{WORKSHEET_PART}\" ContentType=\"#{SPREADSHEET_ML}.worksheet+xml\"/>"
        if shared_strings?
          xml << "<Override PartName=\"/#{SharedStringTable::PART}\" ContentType=\"#{SPREADSHEET_ML}.sharedStrings+xml\"/>"
        end
        xml << "</Types>"
      end
    end
  end
end
