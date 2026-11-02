# frozen_string_literal: true

require "date"

module IOStreams
  class Schema
    # The pattern of the text of a date, datetime or time field, its `format`, such as "%d/%m/%Y", which reads the text
    # of a value, and writes it.
    #
    # Frictionless defines the pattern as the syntax of Python's and C's strptime, see
    # https://datapackage.org/standard/table-schema/, which Ruby's mostly shares, apart from these, which it reads as
    # Python does:
    #   %Y   the year, exactly 4 digits, such as `2026`, where Ruby reads any number of digits, so that `31/10/26` raises
    #        for `%d/%m/%Y`, rather than read the year 26. `%y` reads the year of 2 digits, as before.
    #   %f   the microseconds of the second, 1 to 6 digits when read, such as `.5` for half a second, and 6 digits when
    #        written, such as `.500000`, which Ruby does not have.
    #
    # Ruby's own directives still work, such as `%N` and `%L` for the fraction of a second, and `%s` for the seconds since
    # 1970, but other Frictionless tools do not read them.
    class Pattern
      # The prefix of a pattern in Data Package v0, which a field removes, as Frictionless requires, see
      # `IOStreams::Schema::Field`.
      PREFIX = "fmt:"

      # A directive of a pattern, or `%%`, which is a `%`: its flags and width, which never match the same characters,
      # since a width does not start with `0`, which is a flag, and its letter.
      DIRECTIVE = /%(?:%|[-_0^#:]*(?:[1-9]\d*)?([a-zA-Z+]))/

      # The letters of the directives that strptime reads as digits, which shorten the digits that the directive before
      # them reads, such as `%Y%m%d`, see #digits_follow?.
      NUMERIC = "CDdeFGgHIjkLlMmNQRrSsTUuVvWwXxYy"

      # The digits that a directive whose width Ruby does not check must read, see #parts, by its letter.
      DIGITS = {"Y" => 4..4, "f" => 1..6}.freeze

      # The letters of the directives of a zone, which a pattern that says its offset from UTC has.
      ZONES = %w[z Z +].freeze

      # Parameters:
      #   pattern: [String]
      #     The strptime pattern, such as "%d/%m/%Y", without the prefix `fmt:`.
      def initialize(pattern)
        @pattern = -pattern
        @read    = +""
        @write   = +""
        # The pattern read before each directive whose digits are checked, the digits that it reads, and whether digits
        # follow it, see #parts.
        @checks  = []
        @zone    = false
        build
        @read  = -@read
        @write = -@write
        @checks.freeze
        freeze
      end

      # Returns [true|false] whether the pattern writes a zone, such as `%z`, `%:z` or `%Z`, so that a time written with
      # it says its own offset from UTC.
      def zone?
        @zone
      end

      # Returns [Hash|nil] the parts of the text read with the pattern, as `Date._strptime` returns them, such as
      # `{year: 2026, mon: 10, mday: 13}`, or nil when the pattern does not match all of the text, or a directive does
      # not read the digits that it must, see DIGITS.
      def parts(text)
        parts = Date._strptime(text, @read)
        return if parts.nil? || parts.key?(:leftover)

        parts if @checks.all? { |before, digits, followed| digits?(text, before, digits, followed) }
      end

      # Returns [Date] the date of the text, which #parts must have matched.
      #
      # Raises `Date::Error`, an ArgumentError, when the text is not a date that exists.
      def date(text)
        Date.strptime(text, @read)
      end

      # Returns [DateTime] the time of the text, which #parts must have matched.
      #
      # Raises `Date::Error`, an ArgumentError, when the text is not a time that exists.
      def datetime(text)
        DateTime.strptime(text, @read)
      end

      # Returns [String] the text of the Date or Time in the pattern.
      def strftime(value)
        value.strftime(@write)
      end

      private

      # Builds the pattern that Ruby reads and writes, and the directives whose digits are checked.
      def build
        position = 0
        @pattern.scan(DIRECTIVE) do
          match = Regexp.last_match
          text  = @pattern[position...match.begin(0)]
          @read << text
          @write << text
          letter    = match[1]
          directive = match[0]
          @zone ||= ZONES.include?(letter)
          if DIGITS.key?(letter) && directive.length == 2
            @checks << [-@read.dup, DIGITS.fetch(letter), digits_follow?(match.end(0))]
          end
          @read << (directive == "%f" ? "%N" : directive)
          @write << (directive == "%f" ? "%6N" : directive)
          position = match.end(0)
        end
        rest = @pattern[position..]
        @read << rest
        @write << rest
      end

      # Returns [true|false] whether the pattern after the supplied position starts with digits, or a directive that
      # reads them, so that the directive before it stops at its own digits.
      def digits_follow?(position)
        rest = @pattern[position..]
        return true if rest.match?(/\A\d/)

        directive = DIRECTIVE.match(rest)
        !directive.nil? && directive.begin(0).zero? && !directive[1].nil? && NUMERIC.include?(directive[1])
      end

      # Returns [true|false] whether the text after the part that the pattern before the directive reads starts with
      # the supplied number of digits: no more, unless digits follow the directive, see #digits_follow?, which read the
      # digits after its own.
      def digits?(text, before, digits, followed)
        rest = before.empty? ? text : leftover(text, before)
        return false if rest.nil?

        count = rest[/\A\d*/].length
        followed ? count >= digits.min : digits.cover?(count)
      end

      # Returns [String|nil] the text after the part that the pattern reads, or nil when the pattern does not read its
      # start.
      def leftover(text, pattern)
        parts = Date._strptime(text, pattern)
        return if parts.nil?

        parts.fetch(:leftover, "")
      end
    end
  end
end
