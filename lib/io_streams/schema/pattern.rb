# frozen_string_literal: true

require "date"

module IOStreams
  class Schema
    # The pattern of the text of a date or datetime field, its `format`, which Frictionless writes in the syntax of
    # Python and C's strptime, see https://datapackage.org/standard/table-schema/, and which IOStreams reads and writes
    # with Ruby's strptime and strftime, whose directives are mostly the same:
    #   %Y  the year in exactly 4 digits, as Python reads it, such as "2026", where Ruby reads as many digits as there
    #       are, so that "26" would be the year 26. So does `%G`, the year of an ISO 8601 week.
    #   %y  the year of the century in exactly 2 digits, as Python reads it, such as "05", where Ruby also reads "5".
    #   %f  the microseconds, which Ruby does not have: 1 to 6 digits of the fraction of a second when reading, such as
    #       "5" for half a second, and 6 digits when writing, such as "500000".
    #   %H  the hour, from 00 to 23, as Python reads it, where Ruby also reads 24, and `%S` the second, from 00 to 59,
    #       where Ruby also reads the leap second 60, see #parts.
    #
    # Every other directive is Ruby's, which reads and writes the directives of Python the same way. A directive that
    # reads several, such as `%F`, `%c` or Ruby's `%+`, reads its year as they do, see COMPOSITES. Ruby's own
    # directives, such as `%N`, `%L`, `%s` and `%+`, still work, but other Frictionless tools do not read them, and `%s`
    # reads whole seconds, so that the fraction after it, such as in `%s.%f`, is ignored.
    class Pattern
      # A directive of a pattern: `%%`, or `%` with its flags, width, modifier `E` or `O`, and letter, such as `%d`,
      # `%-m`, `%:z` or `%EY`, whose letter is captured. A width does not start with `0`, which is a flag, so that the
      # flags and the width never match the same characters, which would take time that grows with the square of their
      # length.
      DIRECTIVE = /%(?:%|[-_0^#:]*(?:[1-9]\d*)?[EO]?([a-zA-Z+]))/

      # The directives that Ruby's strptime reads as a pattern of several, and those patterns, which a pattern is
      # expanded with before it is read, so that the digits of the year in each one are checked, see DIGITS. Writing
      # keeps the directive, which Ruby's strftime writes as that pattern, apart from `%+`, see WRITE_DIRECTIVES.
      COMPOSITES = {
        "%+" => "%a %b %e %H:%M:%S %Z %Y",
        "%c" => "%a %b %e %H:%M:%S %Y",
        "%D" => "%m/%d/%y",
        "%F" => "%Y-%m-%d",
        "%v" => "%e-%b-%Y",
        "%x" => "%m/%d/%y"
      }.freeze

      # A directive with the modifier `E` or `O`, of the alternative form of a locale, which Ruby's strptime reads as the
      # directive without it, such as `%EY` as `%Y`, see #expand.
      MODIFIED = /\A%(?:E([cCxXyY])|O([deHImMSuUVwWy]))\z/

      # The directive of Python's microseconds, which Ruby does not have.
      MICROSECONDS = "%f"

      # The directives that Ruby's strptime does not read, and those of Ruby that read them: the microseconds.
      READ_DIRECTIVES = {MICROSECONDS => "%N"}.freeze

      # The directives that Ruby's strftime of a Time does not write, and those of Ruby that write them: the
      # microseconds, in 6 digits, and `%+`, the form of date(1), as the strftime of a Date writes it, with the offset
      # of its zone, such as "Sat Oct 31 09:30:00 +00:00 2026".
      WRITE_DIRECTIVES = {MICROSECONDS => "%6N", "%+" => "%a %b %e %H:%M:%S %:z %Y"}.freeze

      # The directives whose digits Ruby counts differently than Python, and the digits that Python reads for each one.
      DIGITS = {"%Y" => "\\d{4}", "%G" => "\\d{4}", "%y" => "\\d{2}", MICROSECONDS => "\\d{1,6}"}.freeze

      # The letters of the directives that write a zone, see #zone?.
      ZONES = %w[z Z +].freeze

      # The start of a pattern of Ruby's strptime that reads a number, after which a directive before it that reads as
      # many digits as there are reads only its own number of them, see #checks.
      NUMERIC = /\A(?:\d|%[EO]?[CDdeFGgHIjkLlMmNQRrSsTUuVvWwXxYy\d])/

      # Parameters:
      #   pattern: [String]
      #     The pattern, such as "%d/%m/%Y", in the syntax of Python's strptime.
      def initialize(pattern)
        read    = expand(pattern)
        @write  = -ruby(pattern, WRITE_DIRECTIVES)
        @read   = -ruby(read, READ_DIRECTIVES)
        @checks = checks(read).freeze
        @zone   = pattern.scan(DIRECTIVE).flatten.compact.intersect?(ZONES)
        freeze
      end

      # Returns [true|false] whether the pattern writes a zone, such as `%z`, `%:z` or `%Z`, so that a time written
      # with it says its own offset from UTC.
      def zone?
        @zone
      end

      # Returns [String] the text of the Date or Time in the pattern.
      def strftime(value)
        value.strftime(@write)
      end

      # Returns [Hash] the parts of the text, as `Date._strptime` returns them, such as `{year: 2026, mon: 10}`.
      # Returns nil when the pattern does not match all of the text, or a year does not have exactly 4 digits, or 2 for
      # `%y`, or microseconds 1 to 6, or its time is not on a clock, see #clock?, as Python reads them.
      def parts(text)
        parts = Date._strptime(text, @read)
        return if parts.nil? || parts.key?(:leftover) || !clock?(parts)

        parts if @checks.all? { |prefix, digits| digits.match?(text, offset(text, prefix)) }
      end

      # Returns [Date] the date of the text, which #parts must have matched.
      def date(text)
        Date.strptime(text, @read)
      end

      # Returns [DateTime] the time of the text, which #parts must have matched.
      def datetime(text)
        DateTime.strptime(text, @read)
      end

      private

      # Returns [true|false] whether the time of the parts is on a clock, from 00:00:00 to 23:59:59, as Python's strptime
      # reads it, for a date as for a time, rather than the hour 24 of `%H`, which `DateTime` moves into the next day, or
      # a leap second, 60 of `%S`, which it reads as the second before it, and `Date` ignores. Ruby's strptime reads no
      # minute of 60 or more.
      def clock?(parts)
        parts.fetch(:hour, 0) < 24 && parts.fetch(:sec, 0) < 60
      end

      # Returns [String] the pattern with each directive that reads several replaced with them, see COMPOSITES, and the
      # modifier of each directive that has one removed, see MODIFIED, which Ruby's strptime reads the same way.
      def expand(pattern)
        pattern.gsub(DIRECTIVE) do |directive|
          modified = MODIFIED.match(directive)
          directive = "%#{modified[1] || modified[2]}" if modified
          COMPOSITES.fetch(directive, directive)
        end
      end

      # Returns [String] the pattern of Ruby's strptime or strftime of the pattern of Python, with each of the supplied
      # directives replaced with its own, see READ_DIRECTIVES and WRITE_DIRECTIVES.
      def ruby(pattern, directives)
        pattern.gsub(DIRECTIVE) { |directive| directives.fetch(directive, directive) }
      end

      # Returns [Array(String, Regexp)] for each directive whose digits Ruby counts differently than Python, see DIGITS,
      # the pattern of Ruby's strptime before it, which finds where its text starts, see #offset, and the digits that
      # Python reads there. Ruby reads as many digits as there are unless the pattern reads a number right after it, so
      # then those after the digits are not checked.
      def checks(pattern)
        checks = []
        pattern.scan(DIRECTIVE) do
          match  = Regexp.last_match
          digits = DIGITS[match[0]]
          next unless digits

          after  = NUMERIC.match?(ruby(match.post_match, READ_DIRECTIVES)) ? "" : "(?!\\d)"
          checks << [-ruby(match.pre_match, READ_DIRECTIVES), Regexp.new("\\G#{digits}#{after}")]
        end
        checks
      end

      # Returns [Integer] where the text of the directive after the prefix starts: after the text that the prefix reads.
      def offset(text, prefix)
        return 0 if prefix.empty?

        parts = Date._strptime(text, prefix)
        return text.length if parts.nil?

        text.length - parts.fetch(:leftover, "").length
      end
    end
  end
end
