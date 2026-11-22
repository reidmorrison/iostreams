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
    #   zone, or the text of one that Excel does not show, see #holds_date?, and a TimeOfDay a time of day, each the
    #   number of its day in the date system of the workbook, see `IOStreams::Xlsx::DateSystem`, of its style, see
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

      # The most characters of the text of a cell, counted in UTF-16, as Excel limits it, see
      # `IOStreams::Xlsx::Text.length`, beyond which Excel reports the workbook as corrupt.
      MOST_CHARACTERS = 32_767

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
      # Raises [IOStreams::Errors::Error] for a row after Excel's last, a value of a cell after its last column, or text
      # longer than a cell holds, see MOST_CHARACTERS, which Excel would report as corrupt, so that the write is
      # discarded rather than leave a workbook that cannot be read.
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
      # `IOStreams::Xlsx::DateSystem#holds?`, of which the worksheet writes any other as its text, so that
      # `IOStreams::Xlsx::RowsWriter` keeps the text that `auto_format` reads as one instead.
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
        when Time then add_time(xml, value, index)
        when DateTime then add_time(xml, value.to_time, index)
        when Date then add_date(xml, value, index)
        when TimeOfDay then xml << styled(index, CellStyles::TIME_OF_DAY, value.seconds / SECONDS_PER_DAY)
        when Decimal then xml << styled(index, @styles.decimals(value.decimals), value.number)
        else add_text(xml, value.to_s, index)
        end
      end

      # Returns [String] the cell of a number of the style.
      def styled(index, style, number)
        %(<c r="#{reference(index)}" s="#{style}"><v>#{number}</v></c>)
      end

      # Adds the cell of a date that a cell holds, see #holds_date?, otherwise its text, such as `1899-12-31`, rather than
      # a number that Excel shows as another date, or as `####`.
      def add_date(xml, date, index)
        return add_text(xml, date.iso8601, index) unless @date_system.holds?(date)

        xml << styled(index, CellStyles::DATE, @date_system.day(date))
      end

      # Adds the cell of a date and time that a cell holds, see #holds_date?, of the clock of its offset, otherwise the
      # text of that clock, see `IOStreams::Schema::Field.clock_text`, such as `1899-12-31T12:00:00`, rather than a number
      # of less than 1, which is a time of day.
      def add_time(xml, time, index)
        clock = clock(time)
        return add_text(xml, Schema::Field.clock_text(clock), index) unless @date_system.holds?(clock)

        xml << styled(index, CellStyles::DATE_TIME, @date_system.days(clock))
      end

      # Returns [Time] the clock of the time in UTC, the one that the cell holds, so that whether a cell holds it is
      # asked of the clock that is written, rather than of the moment of a time of another offset.
      def clock(time)
        return time if time.utc_offset.zero?

        Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec + time.subsec)
      end

      def flush
        @output << @buffer
        @buffer = +""
      end

      def add_text(xml, text, index)
        return if text.empty?

        # Text of no more bytes than the limit is within it, since each code unit of UTF-16 takes a byte or more.
        text = check_length(text, index) if text.bytesize > MOST_CHARACTERS
        text = Text.encode(text)
        xml << if @shared_strings
                 %(<c r="#{reference(index)}" t="s"><v>#{@shared_strings.index(text)}</v></c>)
               else
                 %(<c r="#{reference(index)}" t="inlineStr"><is>#{Text.element(text)}</is></c>)
               end
      end

      # Returns [String] the text in UTF-8, which it counts, so that it is not converted again.
      #
      # Raises [IOStreams::Errors::Error] for text longer than a cell holds, see MOST_CHARACTERS, so that the write is
      # discarded rather than leave a workbook that Excel reports as corrupt.
      def check_length(text, index)
        text   = Text.utf8(text)
        length = Text.length(text)
        return text if length <= MOST_CHARACTERS

        raise(Errors::Error, "A cell holds at most #{MOST_CHARACTERS} characters, counted in UTF-16, as Excel limits " \
                             "it, which the text of cell #{reference(index)}, of #{length}, exceeds")
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
