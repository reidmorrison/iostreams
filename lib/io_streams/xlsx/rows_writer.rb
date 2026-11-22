# frozen_string_literal: true

require "date"

module IOStreams
  module Xlsx
    # Writes rows to a worksheet, each an Array of the values of its cells, which keep their types, see
    # `IOStreams::Xlsx::Writer.stream`'s `rows: true`, so that a number is a number, a Date or Time a date or time, and
    # text is text, such as `01234`, rather than every cell text, or a guess, or nil for a blank row, written as a row
    # without cells. A time is written in UTC, and a date or time that Excel does not show, before 1900-01-01 or after
    # 9999-12-31, as its text, see `IOStreams::Xlsx::WorksheetWriter#holds_date?`, a BigDecimal as the Float that Excel
    # holds, or its digits when a double cannot hold it,
    # a whole number of more digits than Excel keeps, or NaN or an infinity, as its text, a Hash or an Array as its
    # JSON, and any other value as its text, see `IOStreams::Schema::Field.any_text`.
    #
    # With `auto_format`, the text of a column whose type is not known, of a field of type "any" or without a schema, is
    # written as the number, date, time or boolean that it looks like, such as "1.5" or "2026-10-09", while the text of
    # a column of a `string` field is written as it is.
    class RowsWriter
      # The text that `auto_format` writes as a number, a date, a time or a boolean.
      NUMBER  = /\A-?[0-9]+(\.[0-9]+)?\z/
      DATE    = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/
      TIME    = /\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\.[0-9]{1,9})?)?(?:Z|[+-][0-9]{2}:[0-9]{2})?\z/
      BOOLEAN = {"true" => true, "false" => false}.freeze

      # The whole numbers that Excel holds with all of their digits, of at most the 15 significant digits that it keeps.
      EXACT = 10**15

      # Parameters
      #   worksheet: [IOStreams::Xlsx::WorksheetWriter]
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
      #     as times of day, the clock of each value, rather than as dates and times.
      #
      #   number_columns: [Hash<Integer, IOStreams::Schema::Field>|nil]
      #     The fields of the columns whose values are numbers, a `number` or an `integer`, by their positions, whose
      #     cells show each number with the `decimals` of its field, if any, such as `12.50`, and hold the text of the
      #     field for a number that a cell cannot hold as a number, see #number_cell.
      def initialize(worksheet, auto_format: false, text_columns: nil, time_columns: nil, number_columns: nil)
        @worksheet       = worksheet
        @auto_format     = auto_format
        @text_columns    = (text_columns || []).to_h { |index| [index, true] }
        @time_columns    = (time_columns || []).to_h { |index| [index, true] }
        @number_columns = number_columns || {}
      end

      # Writes the row, an Array of the values of its cells, see the class, or a row without cells for nil, a blank row,
      # which the tabular renders for a row or record without values, as a format of lines writes a blank line.
      def <<(row)
        @worksheet << (row.nil? ? [] : row.each_with_index.map { |value, index| cell(value, index) })
        self
      end

      # Ends the rows. The workbook is ended by `IOStreams::Xlsx::Writer.stream`.
      def finish
        nil
      end

      private

      # Returns the value of the cell at the supplied position, in a form that `IOStreams::Xlsx::WorksheetWriter` writes
      # as its type: a time in UTC, as `IOStreams::Xlsx::Cells` reads the clock of a cell, since the worksheet writes the
      # clock of a time without its offset, which for a field with a `timeZone` is already the clock of its zone, as the
      # field renders it, see `IOStreams::Schema::Field#render`, see #time_cell, and a number that a cell cannot hold, see
      # #number, as its text.
      def cell(value, index)
        case value
        when DateTime then time_cell(value.to_time, index)
        when Time then time_cell(value, index)
        when nil, true, false then value
        when Date then @worksheet.holds_date?(value) ? value : value.iso8601
        when Integer, Float then number_cell(value, index)
        when String then @auto_format && !@text_columns.key?(index) ? auto_format(value) : value
        else value.is_a?(::BigDecimal) ? number_cell(value, index) : IOStreams::Schema::Field.any_text(value)
        end
      end

      # Returns [WorksheetWriter::TimeOfDay|Time|String] the cell of a time: of a column of times of day, its clock,
      # otherwise the time in UTC, or the text of its clock, as the CSV text of a cell holds it, see
      # `IOStreams::Schema::Field.clock_text`, for one that no cell of a date and time holds, see
      # `IOStreams::Xlsx::WorksheetWriter#holds_date?`, such as 1899-12-31T12:00:00, whose number of days would be that
      # of a time of day, 0.5, so that only a cell of a time of day holds a number of less than 1.
      def time_cell(time, index)
        return time_of_day(time) if @time_columns.key?(index)

        time = time.getutc
        @worksheet.holds_date?(time) ? time : IOStreams::Schema::Field.clock_text(time)
      end

      # Returns [Numeric|String] the number, as a number of Excel, a double of which it keeps 15 significant digits, or
      # its text when Excel would change it: a whole number of more than 15 digits, such as an identifier, which a
      # contract's `integer` or `number` field reads back whole, and NaN or an infinity, which Excel has no number for,
      # as the text that a number field reads, such as "NaN" or "INF", see `IOStreams::Schema::Field.special_text`. A
      # BigDecimal with a fraction is the double that Excel holds, as a number that Excel displays to 15 digits, or its
      # text, such as `1.5e400` in plain digits, when a double loses it, see #lost?, as is a Float smaller than Excel's
      # smallest number. A column of a field writes such text as the field does, see #number_cell.
      def number(value)
        return IOStreams::Schema::Field.special_text(value) unless value.finite?
        return (lost?(value) { value } ? value.to_s : value) if value.is_a?(Float)
        return fraction(value) unless value.is_a?(Integer) || value.frac.zero?
        return value.to_i.to_s if value.abs >= EXACT

        value.is_a?(Integer) ? value : value.to_f
      end

      # Returns the number, date, time or boolean that the text looks like, or the text.
      def auto_format(text)
        return BOOLEAN[text] if BOOLEAN.key?(text)
        return auto_number(text) if NUMBER.match?(text)
        return date_or_text(Date.iso8601(text), text) if DATE.match?(text)
        return date_or_text(DateTime.iso8601(text).to_time.getutc, text) if TIME.match?(text)

        text
      rescue ArgumentError
        text
      end

      # Returns [WorksheetWriter::Decimal|Numeric|String] the number of the column, see #number, shown with the
      # `decimals` of the field of its column, if it has them, or for a number that #number writes as text, the text of
      # the field, as CSV writes it, such as `12345678901234567.00` for 2 decimals, see `IOStreams::Schema::Field#render`,
      # or without a field, as #number writes it.
      def number_cell(value, index)
        number = number(value)
        field  = @number_columns[index]
        return number unless field
        return field.render(value, :text) unless number.is_a?(Numeric)

        field.decimals ? WorksheetWriter::Decimal.new(number, field.decimals) : number
      end

      # Returns [Float|String] the double of a BigDecimal with a fraction, or its plain digits when it is larger than a
      # double holds, rather than an infinity, which Excel has no number for.
      def fraction(value)
        float = value.to_f
        lost?(float) { value } ? value.to_s("F") : float
      end

      # Returns [true|false] whether the double of the number lost it: an infinity for one larger than a double holds,
      # or, for one other than 0 that is smaller than the smallest normal double, which Excel holds, 0 or a subnormal
      # double, of fewer digits. The number is only built, by the block, when the double is that small.
      def lost?(float)
        return true unless float.finite?

        float.abs < Float::MIN && !yield.zero?
      end

      # Returns [Numeric|String] the number of text that looks like one, as #number writes it, or the text itself for a
      # number that #number writes as text, such as one of 16 digits, with its leading zeros, or that a Float cannot
      # hold, such as one of 400 digits, rather than an infinity.
      def auto_number(text)
        value = text.include?(".") ? text.to_f : text.to_i
        return text if value.is_a?(Float) && lost?(value) { BigDecimal(text) }

        value = number(value)
        value.is_a?(String) ? text : value
      end

      # Returns [WorksheetWriter::TimeOfDay] the clock of the time, as a time of day.
      def time_of_day(time)
        WorksheetWriter::TimeOfDay.new((time.hour * 3600) + (time.min * 60) + time.sec + time.subsec)
      end

      # Returns [Date|Time|String] the date or time of text that looks like one, or the text itself for one that no cell
      # of a date or time holds, see `IOStreams::Xlsx::WorksheetWriter#holds_date?`.
      def date_or_text(value, text)
        @worksheet.holds_date?(value) ? value : text
      end
    end
  end
end
