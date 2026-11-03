# frozen_string_literal: true

module IOStreams
  class Schema
    # The text of the numbers of a `number` or `integer` field, as Frictionless describes it with the properties
    # `groupChar`, `decimalChar` and `bareNumber`, see https://datapackage.org/standard/table-schema/: it turns the text
    # read into the plain text of a number, such as `-1234.50`, which the field reads as its type, and the plain text of a
    # number that the field writes into its text, such as `1,234.50`.
    #
    #   groupChar: [String]
    #     The text that groups the digits of the whole part of a number, such as "," for `1,234,567`, which reading
    #     removes wherever it is, as frictionless-py does, and writing places between each group of 3 digits.
    #     Default: none
    #
    #   decimalChar: [String|nil]
    #     The text of the decimal point of a number, such as "," for `12,50`, so that a "." of the number read that is not
    #     its `groupChar` is not a number, or nil for an integer, which has no decimal point, so that its `groupChar` can
    #     be ".".
    #
    #   bareNumber: [true|false]
    #     Whether the text read is only the number. When false, the text before and after the number that has no digits,
    #     such as the `$` of `$12.50`, the `%` of `95%` or the `abc` of `12abc`, is removed, as Frictionless requires,
    #     a `-` before the number, such as in `-$12.50` or `USD -12`, makes it negative, and so do parentheses around the
    #     text, as accountants write a negative number, such as `(12.50)` or `($12.50)`. Text with digits before or after
    #     the number raises, as does text without a number, a `-` after the number, such as `12-`, which could be its
    #     sign, and a parenthesis without its pair, such as `(12.50`. Writing writes the number alone.
    #     Default: true
    #
    # A number of JSON, or any other value that is not text, is the number itself, so none of these apply to it, and
    # JSON writes its number in the plain form, since a JSON number has neither.
    class NumberText
      # The decimal point of the plain text of a number, which the field reads and writes.
      POINT = "."

      # Text in parentheses, which is a negative number, see `bareNumber`.
      PARENTHESES = /\A\((?<inner>.*)\)\z/m

      # The plain text of a number that a field writes, its sign, its whole part, its fraction and its exponent.
      PLAIN = /\A(?<sign>[+-]?)(?<whole>\d+)(?:\.(?<fraction>\d*))?(?<exponent>[eE][+-]?\d+)?\z/

      # Each digit of the whole part of a number that a `groupChar` follows, since a multiple of 3 digits follows it.
      GROUPED = /\d(?=(?:\d{3})+\z)/

      # The characters that neither `groupChar` nor `decimalChar` can hold, since they are part of the number, or of its
      # text, see `bareNumber`.
      NUMERIC = /[\d+\-eE()]/

      # Returns [IOStreams::Schema::NumberText|nil] the text of the numbers of a field of the supplied properties, or nil
      # when they are the plain text of a number, which the field reads and writes itself.
      #
      # Raises ArgumentError for a property that is not valid, naming the field.
      def self.build(name, group_char: nil, decimal_char: nil, bare_number: nil)
        return if group_char.nil? && [nil, POINT].include?(decimal_char) && (bare_number.nil? || bare_number == true)

        new(name, group_char: group_char, decimal_char: decimal_char, bare_number: bare_number.nil? || bare_number)
      end

      # Parameters, see above:
      #   name: [String|Symbol]
      #     The name of the field, for the messages of its errors.
      #
      #   group_char: [String|nil]
      #   decimal_char: [String|nil]
      #   bare_number: [true|false]
      #
      # Raises ArgumentError for a property that is not valid.
      def initialize(name, group_char: nil, decimal_char: nil, bare_number: true)
        @name         = name
        @group_char   = check_char("groupChar", group_char)
        @decimal_char = check_char("decimalChar", decimal_char)
        @bare         = check_bare(bare_number)
        if @group_char && @group_char == @decimal_char
          raise(ArgumentError, "Field #{name.inspect}: groupChar and decimalChar cannot be the same: #{@group_char.inspect}")
        end

        # Replaces each digit that GROUPED matches with itself followed by the `groupChar`, as the text of a replacement.
        @grouping = "\\0#{@group_char.gsub('\\') { '\\\\' }}" if @group_char
        @number   = number_pattern unless @bare
        freeze
      end

      # Returns [String|nil] the plain text of the number of the text read, such as "-1234.50" for "(1,234.50)" with
      # `groupChar: ","` and `bareNumber: false`, which the field reads as its type, or nil when the text holds no number
      # in this form, such as a number with a "." that is not the decimal point.
      def read(text)
        text = text.gsub(@group_char, "") if @group_char
        @bare ? plain(text) : unwrap(text)
      end

      # Returns [String] the text of the number of the plain text that the field writes, such as "1,234.50" for
      # "1234.50" with `groupChar: ","`, or the text as it is when it is not a number, such as "NaN" or "INF".
      def write(text)
        plain = PLAIN.match(text)
        return text unless plain

        whole    = plain[:whole]
        whole    = whole.gsub(GROUPED, @grouping) if @group_char
        fraction = plain[:fraction]
        "#{plain[:sign]}#{whole}#{"#{@decimal_char || POINT}#{fraction}" if fraction}#{plain[:exponent]}"
      end

      private

      # Returns [String|nil] the plain text of the number, whose decimal point is its `decimalChar`, or nil when it has
      # a "." that is not its decimal point.
      def plain(number)
        return number if @decimal_char.nil? || @decimal_char == POINT
        return if number.include?(POINT)

        number.gsub(@decimal_char, POINT)
      end

      # Returns [String|nil] the number within the text, without the text before and after it, negative when it is in
      # parentheses, or a `-` comes before it, see `bareNumber`, or nil when there is no number, or digits remain before
      # or after it, or it has a sign twice, or a `-` follows it, or a parenthesis has no pair.
      def unwrap(text)
        inner    = PARENTHESES.match(text)
        negative = !inner.nil?
        text     = inner[:inner] if inner
        parts    = @number.match(text.strip)
        return if parts.nil?

        lead  = parts[:lead]
        trail = parts[:trail]
        return if trail.include?("-") || !paired?(lead) || !paired?(trail)

        number = plain(parts[:number])
        return if number.nil?

        signs  = lead.count("+-")
        signed = number.start_with?("+", "-")
        return if signs > 1 || (signs == 1 && signed) || (negative && (signs == 1 || signed))

        negative ||= lead.include?("-")
        negative ? "-#{number.delete_prefix('+')}" : number
      end

      # Returns [Regexp] the number within text, whose decimal point is the `decimalChar`, and the text before and after
      # it, which has no digits, see `bareNumber`. A point without digits after it, such as `12.`, is part of the number,
      # and so is a point before its digits, such as `.5`, unless a letter or a point comes before it, such as the `Rs.`
      # of `Rs.500`, or the `No.` of `No.5`.
      def number_pattern
        point  = Regexp.escape(@decimal_char || POINT)
        number = /[+-]?(?:\d+(?:#{point}\d*)?|(?<![[:alpha:].])(?<!#{point})#{point}\d+)(?:[eE][+-]?\d+)?/
        /\A(?<lead>[^\d]*?)(?<number>#{number})(?<trail>[^\d]*)\z/m
      end

      # Returns [true|false] whether each parenthesis of the text has its pair after it.
      def paired?(text)
        return true unless text.include?("(") || text.include?(")")

        depth = 0
        text.each_char do |char|
          depth += 1 if char == "("
          depth -= 1 if char == ")"
          return false if depth.negative?
        end
        depth.zero?
      end

      def check_char(property, char)
        return if char.nil?
        return -char if char.is_a?(String) && !char.empty? && !NUMERIC.match?(char)

        raise(ArgumentError, "Field #{@name.inspect}: #{property} must be text without digits, a sign, an exponent or a " \
                             "parenthesis: #{char.inspect}")
      end

      def check_bare(bare)
        return bare if [true, false].include?(bare)

        raise(ArgumentError, "Field #{@name.inspect}: bareNumber must be true or false: #{bare.inspect}")
      end
    end
  end
end
