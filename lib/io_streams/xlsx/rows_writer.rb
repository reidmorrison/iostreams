# frozen_string_literal: true

require "date"

module IOStreams
  module Xlsx
    # Writes rows to a worksheet, each an Array of the values of its cells, which keep their types, see
    # `IOStreams::Xlsx::Writer.stream`'s `rows: true`, so that a number is a number, a Date or Time a date or time, and
    # text is text, such as `01234`, rather than every cell text, or a guess. A time is written in UTC, and as its text
    # before 1899-12-31, the first date and time of a cell, see #time_cell, a BigDecimal as the Float that Excel holds,
    # a whole number of more digits than Excel keeps, or NaN or an infinity, as its text, a Hash or an Array as its
    # JSON, and any other value as its text, see `IOStreams::Schema::Field.any_text`.
    #
    # With `auto_format`, the text of a column whose type is not known, of a field of type "any" or without a schema, is
    # written as the number, date, time or boolean that it looks like, such as "1.5" or "2026-10-09", while the text of
    # a column of a `string` field is written as it is.
    class RowsWriter
      # The text that `auto_format` writes as a number, a date, a time or a boolean, as `xlsxtream` formats it.
      NUMBER  = /\A-?[0-9]+(\.[0-9]+)?\z/
      DATE    = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/
      TIME    = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\.[0-9]{1,9})?)?(?:Z|[+-][0-9]{2}:[0-9]{2})?\z/
      BOOLEAN = {"true" => true, "false" => false}.freeze

      # The whole numbers that Excel holds with all of their digits, of at most the 15 significant digits that it keeps.
      EXACT = 10**15

      # The first date and time that a cell of a date and time holds, Excel's day 1, before which the number of the cell
      # would be less than 1, as that of a time of day is, see `IOStreams::Xlsx::Workbook`, or negative, which is no
      # date that Excel shows, so that a date and time before it is written as its text, see #time_cell.
      FIRST_DATE_TIME = Time.utc(1899, 12, 31).freeze

      # Parameters
      #   worksheet: [Xlsxtream::Worksheet]
      #     The worksheet that the rows are added to.
      #
      #   auto_format: [true|false]
      #     Whether to write the text of a column whose type is not known as the value that it looks like.
      #
      #   text_columns: [Array<Integer>|nil]
      #     The positions of the columns whose values are text by their field, which `auto_format` leaves as they are.
      #
      #   time_columns: [Array<Integer>|nil]
      #     The positions of the columns whose values are times of day by their field, a `time`, whose cells are written
      #     as times of day, the clock of each value, see `IOStreams::Xlsx::Workbook.time_of_day`, rather than as dates
      #     and times.
      def initialize(worksheet, auto_format: false, text_columns: nil, time_columns: nil)
        @worksheet    = worksheet
        @auto_format  = auto_format
        @text_columns = (text_columns || []).to_h { |index| [index, true] }
        @time_columns = (time_columns || []).to_h { |index| [index, true] }
      end

      # Writes the row, an Array of the values of its cells, see the class.
      def <<(row)
        @worksheet << row.each_with_index.map { |value, index| cell(value, index) }
        self
      end

      # Ends the rows. The workbook is ended by `IOStreams::Xlsx::Writer.stream`.
      def finish
        nil
      end

      private

      # Returns the value of the cell at the supplied position, in a form that `xlsxtream` writes as its type: a time in
      # UTC, as `IOStreams::Xlsx::Cells` reads the clock of a cell, since `xlsxtream` writes the clock of a time without
      # its offset, which for a field with a `timeZone` is already the clock of its zone, as the field renders it, see
      # `IOStreams::Schema::Field#render`, see #time_cell, and a number that a cell cannot hold, see #number, as its text.
      def cell(value, index)
        case value
        when DateTime then time_cell(value.to_time, index)
        when Time then time_cell(value, index)
        when nil, true, false, Date then value
        when Integer, Float then number(value)
        when String then @auto_format && !@text_columns.key?(index) ? auto_format(value) : value
        else value.is_a?(::BigDecimal) ? number(value) : IOStreams::Schema::Field.any_text(value)
        end
      end

      # Returns [Time|String] the cell of a time: of a column of times of day, its clock on Excel's first day, see
      # `IOStreams::Xlsx::Workbook.time_of_day`, otherwise the time in UTC, or the text of its clock, as the CSV text of
      # a cell holds it, see `IOStreams::Schema::Field.clock_text`, before FIRST_DATE_TIME, such as 1899-12-30T12:00:00,
      # the zero date of OLE, whose number of days would be that of a time of day, 0.5, so that only a cell of a time of
      # day holds a number of less than 1.
      def time_cell(time, index)
        return Workbook.time_of_day(time) if @time_columns.key?(index)

        time = time.getutc
        time < FIRST_DATE_TIME ? IOStreams::Schema::Field.clock_text(time) : time
      end

      # Returns [Numeric|String] the number, as a number of Excel, a double of which it keeps 15 significant digits, or
      # its text when Excel would change it: a whole number of more than 15 digits, such as an identifier, which a
      # contract's `integer` or `number` field reads back whole, and NaN or an infinity, which Excel has no number for,
      # as the text that a number field reads, such as "NaN" or "INF", see `IOStreams::Schema::Field.special_text`. A
      # BigDecimal with a fraction is the double that Excel holds, as a number that Excel displays to 15 digits.
      def number(value)
        return IOStreams::Schema::Field.special_text(value) unless value.finite?
        return value if value.is_a?(Float)
        return value.to_f unless value.is_a?(Integer) || value.frac.zero?
        return value.to_i.to_s if value.abs >= EXACT

        value.is_a?(Integer) ? value : value.to_f
      end

      # Returns the number, date, time or boolean that the text looks like, or the text, as `xlsxtream` formats it.
      def auto_format(text)
        return BOOLEAN[text] if BOOLEAN.key?(text)
        return text.include?(".") ? text.to_f : text.to_i if NUMBER.match?(text)
        return Date.iso8601(text) if DATE.match?(text)
        return early_text(DateTime.iso8601(text).to_time.getutc, text) if TIME.match?(text)

        text
      rescue ArgumentError
        text
      end

      # Returns [Time|String] the time of text that looks like one, or the text itself for a time before
      # FIRST_DATE_TIME, see #time_cell.
      def early_text(time, text)
        time < FIRST_DATE_TIME ? text : time
      end
    end
  end
end
