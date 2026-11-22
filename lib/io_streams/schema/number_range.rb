# frozen_string_literal: true

require "bigdecimal"

module IOStreams
  class Schema
    # The range of the magnitude of a finite number that a `number` or `integer` field reads, and of the coordinates of
    # a `geopoint`, so that the plain text that IOStreams writes for a number, such as "1000000" for the text "1e6",
    # which never uses an exponent, has a bounded number of characters: a number is held as a BigDecimal, which holds
    # the text "1e999999999" in a few bytes, while its plain text has a billion digits, which writing it to CSV or
    # JSON, or storing it in a slice, would build in memory.
    #
    # The range is that of IEEE 754 decimal128, the widest decimal of a fixed size, which BSON and the databases that
    # hold decimals in a fixed size use: below 1e6145 in magnitude, and 1e-6176 or more unless it is 0. It holds every
    # Float, whose range is 1e308 to 5e-324, and every number of a decimal column of a database, of a spreadsheet and
    # of a Parquet file, while the plain text of a number within it has at most 6177 digits on either side of its
    # decimal point, besides the digits of the text that it was read from.
    #
    # Infinity and NaN are not finite, so they are never outside the range.
    module NumberRange
      # The largest exponent of a number within the range, in scientific notation, such as 6144 of 9.99e6144.
      MAX_EXPONENT = 6144

      # The smallest exponent of a number within the range, in scientific notation, such as -6176 of 1e-6176.
      MIN_EXPONENT = -6176

      # The most digits after the decimal point that a number within the range has without trailing zeros, those of
      # 1e-6176, so that a field with more `decimals` would write only zeros after them.
      MAX_DECIMALS = -MIN_EXPONENT

      # The text that describes the range, for the messages of errors.
      DESCRIPTION = "a number must be below 1e#{MAX_EXPONENT + 1} in magnitude, and 1e#{MIN_EXPONENT} or more " \
                    "unless it is 0".freeze

      # The text that describes the range of an Integer, for the messages of errors.
      INTEGER_DESCRIPTION = "an integer must be below 1e#{MAX_EXPONENT + 1} in magnitude".freeze

      # The magnitude of the smallest Integer that is outside the range, 1e6145.
      INTEGER_LIMIT = 10**(MAX_EXPONENT + 1)

      # The most digits of an Integer within the range, without its leading zeros.
      INTEGER_DIGITS = MAX_EXPONENT + 1

      # The first digit of the text of an Integer that is not a leading zero.
      SIGNIFICANT = /[1-9]/

      # The magnitude of the smallest Rational within the range that is not 0, 1e-6176.
      SMALLEST = Rational(1, 10**-MIN_EXPONENT)

      # A digit other than 0 before the exponent of the text of a number, so that it is not 0.
      NONZERO_DIGITS = /\A[^eE]*[1-9]/

      # The exponent of the text of a number, from its "e" or "E".
      EXPONENT = /[eE].*\z/

      # Returns [true|false] whether the number is within the range, see above: a BigDecimal by its exponent, without
      # building its digits, an Integer, a Float, which always is, and a Rational, which a field turns into a BigDecimal.
      # Its class is asked with `is_a?`, as the field asks it, rather than `case`, so that an object that answers it for
      # a class it stands in for, such as an `ActiveSupport::Duration`, which answers `is_a?(Integer)`, is that class.
      def self.within?(number)
        return true if number.is_a?(Float)
        return -INTEGER_LIMIT < number && number < INTEGER_LIMIT if number.is_a?(Integer)
        return number.zero? || (number.abs >= SMALLEST && number.abs < INTEGER_LIMIT) if number.is_a?(Rational)
        return false unless number.is_a?(::BigDecimal)

        !number.finite? || number.zero? || number.exponent.between?(MIN_EXPONENT + 1, MAX_EXPONENT + 1)
      end

      # Returns [true|false] whether the number is finite and its magnitude is at least that of the smallest number
      # beyond the range, 1e6145: too large, rather than too small, which an integer field also rejects as a fraction.
      def self.above?(number)
        return number <= -INTEGER_LIMIT || number >= INTEGER_LIMIT if number.is_a?(Integer)
        return number.abs >= INTEGER_LIMIT if number.is_a?(Rational)
        return false unless number.is_a?(::BigDecimal) && number.finite? && !number.zero?

        number.exponent > MAX_EXPONENT + 1
      end

      # Returns [BigDecimal|nil] the BigDecimal of the text of a finite number, which `IOStreams::Schema::Field::NUMBER`
      # matches, or nil when it is outside the range, also when its exponent is beyond those that a BigDecimal holds,
      # which BigDecimal reads as Infinity, such as "1e99999999999999999999", or as 0, such as
      # "1e-99999999999999999999", which its digits say it is not. Text whose digits are all 0 is 0 whatever its
      # exponent, so it is read without it: JRuby reads "-0.0e99999999999999999999" as -Infinity.
      #
      # Raises ArgumentError for text that BigDecimal does not read, such as "12." before Ruby 3.4.
      def self.decimal(text)
        return BigDecimal(text.sub(EXPONENT, "")) unless NONZERO_DIGITS.match?(text)

        decimal = BigDecimal(text)
        decimal if decimal.finite? && !decimal.zero? && within?(decimal)
      end

      # Returns [Integer|nil] the Integer of the text of a whole number, an optional sign and at least one digit, see
      # `IOStreams::Schema::Field::INTEGER`, or nil when it is outside the range, by the number of its digits after its
      # leading zeros, before it is read as an Integer, which takes time that grows faster than the number of its
      # digits, such as seconds for a million of them.
      def self.integer(digits)
        first = digits.index(SIGNIFICANT)
        Integer(digits, 10) if first.nil? || digits.length - first <= INTEGER_DIGITS
      end

      # Returns [true|false] whether a field can have the supplied number of `decimals`: no more than MAX_DECIMALS.
      def self.decimals_within?(decimals)
        decimals <= MAX_DECIMALS
      end
    end
  end
end
