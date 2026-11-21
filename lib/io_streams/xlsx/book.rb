# frozen_string_literal: true

require "date"

module IOStreams
  module Xlsx
    # The workbook part of a spreadsheet, `xl/workbook.xml` as Excel names it: its worksheets in the order that the
    # application shows them, its date system, and the parts that its worksheets share, its shared strings and styles.
    class Book
      # The first day of each date system of Excel, as the number 0, see .base_date: of the 1900 date system, a day
      # early, so that the dates from 1900-03-01 are right, since Excel counts 1900-02-29, which was not a day, and of
      # the 1904 date system, of Excel for the Mac before 2011.
      DATE_1900 = Date.new(1899, 12, 30).freeze
      DATE_1904 = Date.new(1904, 1, 1).freeze

      # A worksheet of the workbook: its name, and its part.
      Sheet = Data.define(:name, :part)

      # Parameters:
      #   package: [IOStreams::Xlsx::Package]
      #     The parts of the spreadsheet.
      def initialize(package)
        @package       = package
        @part          = package.workbook_part
        relationships  = package.relationships(@part)
        @related       = relationships.to_h { |relationship| [relationship.id, relationship] }
        @shared_part   = related_part(relationships, "sharedStrings")
        @styles_part   = related_part(relationships, "styles")
        workbook       = package.scan(@part, WorkbookPart.new)
        @date1904      = workbook.date1904
        @sheets        = relationships.empty? ? named_sheets(workbook.sheets) : related_sheets(workbook.sheets)
      end

      # Returns [Array<Sheet>] the worksheets of the workbook, in the order that the application shows them, without
      # its chart sheets and dialog sheets, which hold no rows.
      attr_reader :sheets

      # Returns [Sheet] the first worksheet of the workbook.
      #
      # Raises [IOStreams::Errors::StreamFailure] tagged as `IOStreams::Errors::Corrupt` for a workbook without one.
      def first_sheet
        sheets.first || raise(Zip::Reader.failure(Errors::Corrupt, "The spreadsheet #{@package.display_name} has no worksheet",
                                                  @package.display_name))
      end

      # Returns [Date] the date that the number 0 is in the date system of the workbook, see DATE_1900.
      def base_date
        @date1904 ? DATE_1904 : DATE_1900
      end

      # Returns [Array<String>] the shared strings of the workbook, by their index, as a cell of type `s` names them.
      def shared_strings
        @shared_strings ||= @shared_part ? @package.scan(@shared_part, SharedStrings.new).strings : []
      end

      # Returns [Array<Symbol|nil>] the class of the number format of each style of the workbook, by the index of the
      # style, see `IOStreams::Xlsx::Cells.number_formats`.
      def number_formats
        @number_formats ||=
          if @styles_part
            styles = @package.scan(@styles_part, Styles.new)
            Cells.number_formats(styles.format_codes, styles.format_ids)
          else
            []
          end
      end

      # Yields [Array] each row of the first worksheet, see `IOStreams::Xlsx::Worksheet`, with the value of each cell
      # that the block returns for its text, type and style.
      def each_row(converter, &)
        @package.scan(first_sheet.part, Worksheet.new(converter, &))
        nil
      end

      private

      # Returns [Array<Sheet>] the worksheets of the sheets of the workbook, by their relationships.
      def related_sheets(sheets)
        sheets.filter_map do |name, id|
          relationship = @related[id]
          Sheet.new(name, relationship.target) if relationship&.type == "worksheet"
        end
      end

      # Returns [Array<Sheet>] the worksheets of the sheets of a workbook without a relationships part, as some writers
      # leave out, by the parts that Excel names them, in order, `xl/worksheets/sheet1.xml` for the first, that the
      # package holds.
      def named_sheets(sheets)
        sheets.each_with_index.filter_map do |(name, _id), index|
          part = "xl/worksheets/sheet#{index + 1}.xml"
          Sheet.new(name, part) if @package.part?(part)
        end
      end

      # Returns [String|nil] the part of the first relationship of the type, or the part that Excel names, when the
      # workbook has no relationships part, as some writers leave out, or nil when the package does not hold it, since
      # a workbook need not have shared strings nor styles.
      def related_part(relationships, type)
        part = relationships.find { |relationship| relationship.type == type }&.target
        part ||= "xl/#{type}.xml" if relationships.empty?
        part if part && @package.part?(part)
      end

      # Reads the worksheets of the workbook part, by their names and relationship ids, and its date system.
      class WorkbookPart
        attr_reader :sheets, :date1904

        def initialize
          @sheets   = []
          @date1904 = false
        end

        def start_element(name, attributes)
          case name
          when "sheet"
            @sheets << [attributes["name"], attributes["id"]]
          when "workbookPr"
            date1904  = attributes["date1904"]&.strip
            @date1904 = %w[1 true].include?(date1904)
          end
        end

        def end_element(_name)
        end

        def text(_text)
        end
      end
    end
  end
end
