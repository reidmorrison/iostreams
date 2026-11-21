# frozen_string_literal: true

module IOStreams
  class Schema
    # The range of the magnitude of a finite number that a `number` or `integer` field reads, so that the plain text
    # that IOStreams writes for a number, such as "1000000" for the text "1e6", which never uses an exponent, has a
    # bounded number of characters: a number is held as a BigDecimal, which holds the text "1e999999999" in a few
    # bytes, while its plain text, which writing it to CSV or JSON builds in memory, has a billion digits.
    #
    # The range is that of IEEE 754 decimal128, the widest decimal of a fixed size, which BSON and the databases that
    # hold decimals in a fixed size use: below 1e6145 in magnitude, and 1e-6176 or more unless it is 0. It holds every
    # Float, whose range is 1e308 to 5e-324, and every number of a decimal column of a database or of a spreadsheet,
    # while the plain text of a number within it has at most 6177 digits on either side of its decimal point, besides
    # the digits of the text that it was read from.
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

      # Returns [true|false] whether the number is within the range, see above: a BigDecimal by its exponent, without
      # building its digits, an Integer, a Float, which always is, and a Rational, which a field turns into a BigDecimal.
      def self.within?(number)
        case number
        when Integer then -INTEGER_LIMIT < number && number < INTEGER_LIMIT
        when Float then true
        when Rational then number.zero? || (number.abs >= SMALLEST && number.abs < INTEGER_LIMIT)
        else bigdecimal_within?(number)
        end
      end

      # Returns [true|false] whether the number is a BigDecimal within the range, by its exponent, without building its
      # digits. The bigdecimal gem is loaded only for a number field, so it may not be loaded.
      def self.bigdecimal_within?(number)
        return false unless defined?(::BigDecimal) && number.is_a?(::BigDecimal)

        !number.finite? || number.zero? || number.exponent.between?(MIN_EXPONENT + 1, MAX_EXPONENT + 1)
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
