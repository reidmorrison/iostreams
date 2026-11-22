# frozen_string_literal: true

require "date"

module IOStreams
  module Xlsx
    # Writes the rows of a worksheet as its XML, each an Array of the values of its cells, to the part of the worksheet,
    # by the type of each value, which `IOStreams::Xlsx::RowsWriter` gives it:
    # * an Integer or a Float is a number;
    # * true or false is a boolean;
    # * a Decimal is its number, shown with its decimals;
    # * a Date is a date, a Time or DateTime a date and time, of the clock of its offset, since a cell holds no time
    #   zone, and a TimeOfDay a time of day, each the number of its day in the date system of the workbook, see
    #   `IOStreams::Xlsx::DateSystem`, of its style, see
    #   `IOStreams::Xlsx::CellStyles`;
    # * nil, or empty text, is no cell;
    # * anything else is its text, as Excel escapes it, see `IOStreams::Xlsx::Text.encode`, within the cell, or in the
    #   shared strings of the workbook, see `IOStreams::Xlsx::SharedStringTable`.
    #
    # `IOStreams::Xlsx::Cells` reads each one back as the same value.
    class WorksheetWriter
      # A time of day, by its number of seconds since midnight, which is written as a cell of a time of day, rather
      # than as a date and time.
      TimeOfDay = Data.define(:seconds)

      # A number shown with its number of decimals, of a style of that many, see `IOStreams::Xlsx::CellStyles#decimals`.
      Decimal = Data.define(:number, :decimals)

      SECONDS_PER_DAY = 86_400.0

      # The most rows and columns of a worksheet, as Excel limits them: its last row is 1,048,576 and its last column XFD.
      MOST_ROWS    = 1_048_576
      MOST_COLUMNS = 16_384

      # The size of XML that is collected before it is written to the part, since each write compresses it.
      BUFFER_SIZE = 65_536

      # The XML of the worksheet before and after its rows.
      HEADER = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
               '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>'
      FOOTER = "</sheetData></worksheet>"

      # Parameters
      #   output: [#<<]
      #     The part of the worksheet, which receives its XML.
      #
      #   styles: [IOStreams::Xlsx::CellStyles]
      #     The styles of the workbook, which give the style of a number of decimals.
      #
      #   shared_strings: [IOStreams::Xlsx::SharedStringTable|nil]
      #     The shared strings of the workbook, which hold the text of its cells, or nil to write the text within each
      #     cell.
      #
      #   date_system: [IOStreams::Xlsx::DateSystem]
      #     How the workbook numbers its days, which gives the number of a date or time.
      def initialize(output, styles:, date_system:, shared_strings: nil)
        @output         = output
        @date_system    = date_system
        @styles         = styles
        @shared_strings = shared_strings
        @row_number     = 0
        @columns        = ["A"]
        @buffer         = HEADER.dup
      end

      # Writes the row, an Array of the values of its cells, see the class.
      #
      # Raises [IOStreams::Errors::Error] for a row after Excel's last, or a value of a cell after its last column, which
      # Excel would report as corrupt, so that the write is discarded rather than leave a workbook that cannot be read.
      def <<(row)
        @row_number += 1
        if @row_number > MOST_ROWS
          raise(Errors::Error,
                "A worksheet holds at most #{MOST_ROWS} rows, as Excel limits it, which row #{@row_number} exceeds")
        end

        @buffer << %(<row r="#{@row_number}">)
        row.each_with_index { |value, index| add_cell(@buffer, value, index) }
        @buffer << "</row>"
        flush if @buffer.bytesize >= BUFFER_SIZE
        self
      end

      # Returns [true|false] whether a cell holds the date or time, in UTC, as one that Excel shows, see
      # `IOStreams::Xlsx::DateSystem#holds?`, which `IOStreams::Xlsx::RowsWriter` writes as its text otherwise.
      def holds_date?(value)
        @date_system.holds?(value)
      end

      # Ends the worksheet, once its rows are written.
      def close
        @buffer << FOOTER
        flush
      end

      private

      def add_cell(xml, value, index)
        case value
        when nil then nil
        when Integer, Float then xml << %(<c r="#{reference(index)}" t="n"><v>#{value}</v></c>)
        when true then xml << %(<c r="#{reference(index)}" t="b"><v>1</v></c>)
        when false then xml << %(<c r="#{reference(index)}" t="b"><v>0</v></c>)
        when Time then xml << styled(index, CellStyles::DATE_TIME, @date_system.days(value))
        when DateTime then xml << styled(index, CellStyles::DATE_TIME, @date_system.days(value.to_time))
        when Date then xml << styled(index, CellStyles::DATE, @date_system.day(value))
        when TimeOfDay then xml << styled(index, CellStyles::TIME_OF_DAY, value.seconds / SECONDS_PER_DAY)
        when Decimal then xml << styled(index, @styles.decimals(value.decimals), value.number)
        else add_text(xml, value.to_s, index)
        end
      end

      # Returns [String] the cell of a number of the style.
      def styled(index, style, number)
        %(<c r="#{reference(index)}" s="#{style}"><v>#{number}</v></c>)
      end

      def flush
        @output << @buffer
        @buffer = +""
      end

      def add_text(xml, text, index)
        return if text.empty?

        text = Text.encode(text)
        xml << if @shared_strings
                 %(<c r="#{reference(index)}" t="s"><v>#{@shared_strings.index(text)}</v></c>)
               else
                 %(<c r="#{reference(index)}" t="inlineStr"><is>#{Text.element(text)}</is></c>)
               end
      end

      # Returns [String] the reference of the cell of the column at the index in the current row, such as `B2`.
      def reference(index)
        if index >= MOST_COLUMNS
          raise(Errors::Error, "A worksheet holds at most #{MOST_COLUMNS} columns, to XFD, as Excel limits it, which a " \
                               "value of row #{@row_number}, in column #{index + 1}, exceeds")
        end
        @columns << @columns.last.next while @columns.size <= index
        "#{@columns[index]}#{@row_number}"
      end
    end
  end
end
