# frozen_string_literal: true

module IOStreams
  module Xlsx
    # Reads a workbook into CSV text as `IOStreams::Xlsx::Reader` does, for a file read with a schema, see
    # `IOStreams::Xlsx::Reader.schema_reader`, with the text of each number cell as IOStreams 3.0 gives it, so that a
    # `string` field reads the same text in both, and a field of the type of the cell reads it:
    #   a number              the number that the cell holds, to the 15 significant digits that Excel displays, without
    #                         its number format, such as `2134` for the zip code that creek reads as the Float `2134.0`,
    #                         `0.3` for `0.30000000000000004`, `0.125` for `12.5%`, and `12.5` for a format without
    #                         decimals, see .displayed
    #   a date                in ISO 8601, such as `2026-10-25`
    #   a date and time       the time of its clock in UTC, in ISO 8601, such as `2026-10-25T09:30:00Z`, since Excel has
    #                         no time zone, rather than in the time zone of the process
    #   a time of day         the time of its clock, such as `09:30:00`
    #
    # A number cell is one of the type `n`, or without a type, as Excel writes it, whose number format is a date or a
    # time as IOStreams 3.0 classifies it, see `IOStreams::Xlsx::Cells`, such as the custom format `yyyy-mm-dd` of a
    # date, rather than as creek does, which takes it as a date and time. Every other cell keeps creek's text, such as a
    # text cell, keeping `01234`. A file read without a schema keeps creek's text for every cell, as IOStreams 2.1 read
    # it.
    class SchemaReader < Reader
      # The most significant digits that Excel displays of a number.
      DISPLAYED_DIGITS = 15

      # The whole numbers that a Float holds exactly are below this, so that one keeps every digit, such as a card
      # number of 16 digits, rather than the 15 that Excel displays, see .displayed.
      EXACT = 2**53

      # Returns [String|Object] the text of the number of a cell, a Float, as IOStreams 3.0 gives it: its 15 most
      # significant digits, which Excel displays, rounded half up from its exact value, in plain digits, without a
      # decimal point for a whole number, such as "2134" for `2134.0`, "0.3" for `0.30000000000000004`, or
      # "150000000000000000000" for `1.5e20`, or every digit of a whole number below 2**53, which a Float holds exactly,
      # such as "4111111111111111". Any other value is returned as it is.
      def self.displayed(value)
        return value unless value.is_a?(Float) && value.finite?
        return value.to_i.to_s if value.abs < EXACT && value == value.truncate

        # The exact value of the Float, rounded half up to the digits that Excel displays, counted from the first
        # significant digit of its shortest text, as IOStreams 3.0 rounds it, with Rational, so that reading a
        # spreadsheet does not need bigdecimal. Rounding the exact value, rather than its text, gives the same digits on
        # every Ruby, since JRuby writes the text of some Floats with other digits than Ruby does.
        digits = DISPLAYED_DIGITS - exponent(Rational(value.to_s))
        decimal_text(value.to_r.round(digits, half: :up), digits)
      end

      # Returns [String|nil] the text of a cell of a number type, see the class comment, by the class of its number
      # format, see `IOStreams::Xlsx::Cells.number_formats`, such as `:date`, with the first day of the workbook, or nil
      # for text that is not a finite number, which creek converts. A number of a date or time format that is not a date
      # that Excel holds, such as a negative number, which Excel shows as `####`, is a number.
      def self.number_text(text, style, base_date)
        number = Float(text, exception: false)
        return unless number&.finite?

        Cells.date_text(text, style, base_date) || displayed(number)
      end

      # Returns [Integer] the exponent of the number as a BigDecimal gives it, the place of its first significant digit,
      # such as 4 for 2134, 0 for 0.3, and -6 for 0.0000001.
      def self.exponent(number)
        magnitude = number.abs
        exponent  = magnitude.numerator.to_s.length - magnitude.denominator.to_s.length
        exponent += 1 while magnitude >= 10r**exponent
        exponent -= 1 while magnitude < 10r**(exponent - 1)
        exponent
      end

      # Returns [String] the text of the number rounded to the supplied digits after the decimal point, without a
      # decimal point for a whole number, and without zeros at the end of its fraction, as `BigDecimal#to_s("F")` writes
      # it, such as "0.0000001".
      def self.decimal_text(number, digits)
        return number.to_i.to_s if digits <= 0 || number.denominator == 1

        scaled = (number * (10**digits)).to_i
        text   = scaled.abs.to_s.rjust(digits + 1, "0")
        "#{'-' if scaled.negative?}#{text[0...-digits]}.#{text[-digits..].sub(/0+\z/, '')}"
      end
      private_class_method :exponent, :decimal_text

      # Reads the first worksheet of the workbook, with the text of each number cell as .number_text gives it.
      def initialize(file_name)
        super
        formats = number_formats
        convert_cells do |text, type, style, options|
          self.class.number_text(text, formats[style], options[:base_date]) if type.nil? || type == "n"
        end
      end
    end
  end
end
