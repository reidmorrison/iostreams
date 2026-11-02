# frozen_string_literal: true

module IOStreams
  module Xlsx
    # Reads a workbook into CSV text as `IOStreams::Xlsx::Reader` does, for a file read with a schema, see
    # `IOStreams::Xlsx::Reader.schema_reader`, with the text of each number cell as Excel displays it, such as `2134`
    # for the zip code 2134, rather than the text of the Float that creek reads it as, `2134.0`, so that a `string`
    # field reads the text that Excel shows, as IOStreams 3.0 does. A file read without a schema keeps creek's text, as
    # IOStreams 2.1 read it.
    class SchemaReader < Reader
      # The most significant digits that Excel displays of a number.
      DISPLAYED_DIGITS = 15

      # Returns [Object] the value of a cell as the CSV text holds it: a number as the text that Excel displays, see
      # above, of its most significant 15 digits, such as "0.3" for the Float `0.30000000000000004`, without a decimal
      # point for a whole number, and any other value as it is, such as text or a Date.
      def self.displayed(value)
        if value.is_a?(Float)
          return value unless value.finite?

          shown = Float(format("%.#{DISPLAYED_DIGITS}g", value))
          shown == shown.truncate && shown.abs < 10**DISPLAYED_DIGITS ? shown.to_i.to_s : shown.to_s
        elsif defined?(::BigDecimal) && value.is_a?(::BigDecimal) && value.finite?
          value.frac.zero? ? value.to_i.to_s : value.to_s("F")
        else
          value
        end
      end

      # Yields [Array] the values of each row of the first worksheet, with each number as Excel displays it, see
      # .displayed.
      def each
        super { |values| yield values.map { |value| self.class.displayed(value) } }
      end
    end
  end
end
