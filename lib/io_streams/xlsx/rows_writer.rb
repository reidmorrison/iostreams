# frozen_string_literal: true

require "date"

module IOStreams
  module Xlsx
    # Writes rows to a worksheet, each an Array of the values of its cells, which keep their types, see
    # `IOStreams::Xlsx::Writer.stream`'s `rows: true`, so that a number is a number, a Date or Time a date or time, and
    # text is text, such as `01234`, rather than every cell text, or a guess. A BigDecimal is written as the Float that
    # Excel holds, a Hash or an Array as its JSON, and any other value as its text, see
    # `IOStreams::Schema::Field.any_text`.
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

      # Parameters
      #   worksheet: [Xlsxtream::Worksheet]
      #     The worksheet that the rows are added to.
      #
      #   auto_format: [true|false]
      #     Whether to write the text of a column whose type is not known as the value that it looks like.
      #
      #   text_columns: [Array<Integer>|nil]
      #     The positions of the columns whose values are text by their field, which `auto_format` leaves as they are.
      def initialize(worksheet, auto_format: false, text_columns: nil)
        @worksheet    = worksheet
        @auto_format  = auto_format
        @text_columns = (text_columns || []).to_h { |index| [index, true] }
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

      # Returns the value of the cell at the supplied position, in a form that `xlsxtream` writes as its type.
      def cell(value, index)
        case value
        when nil, true, false, Integer, Float, Date, Time then value
        when String then @auto_format && !@text_columns.key?(index) ? auto_format(value) : value
        else defined?(::BigDecimal) && value.is_a?(::BigDecimal) ? value.to_f : IOStreams::Schema::Field.any_text(value)
        end
      end

      # Returns the number, date, time or boolean that the text looks like, or the text, as `xlsxtream` formats it.
      def auto_format(text)
        return BOOLEAN[text] if BOOLEAN.key?(text)
        return text.include?(".") ? text.to_f : text.to_i if NUMBER.match?(text)
        return Date.iso8601(text) if DATE.match?(text)
        return Time.iso8601(text) if TIME.match?(text)

        text
      rescue ArgumentError
        text
      end
    end
  end
end
