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
    # Nothing is read on the day that it is read, as Ruby's strptime reads a date that the text leaves out, or part of
    # one, so that a file reads the same on every day. As Python reads them:
    # - A pattern that reads a day of the month, `%d` or `%e`, without a year, `%Y`, `%y` or `%G`, such as `%m/%d`,
    #   raises ArgumentError when it is created, as Python's strptime does from 3.15, since it cannot read February 29.
    #   So does one that reads an ISO 8601 week, `%G` or `%V`, without the year, week and weekday that give its date,
    #   see #check_date.
    # - Text without a year, such as that of `%H:%M`, `%m %H:%M` or `%I:%M %p`, is on 1900-01-01, in the month that it
    #   reads, and the day of the year of `%j` counts from 1900-01-01, while a weekday or a week, such as `%a` or `%U`,
    #   is ignored, see #default_date.
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

      # The year, month and day that Python's strptime gives the parts of a date that text without a year leaves out,
      # see #default_date.
      DEFAULT_DATE = [1900, 1, 1].freeze

      # The parts of the text, as `Date._strptime` returns them, that give its year, with which Ruby's strptime reads its
      # date as Python's does, see #dated?: the year of `%Y` or `%y`, that of an ISO 8601 week, `%G`, and the seconds
      # since 1970 of `%s` and `%Q`.
      YEAR_PARTS = %i[year cwyear seconds].freeze

      # The letters of the directives that read a year, which a pattern that reads a day of the month needs, see
      # #check_date: `%Y`, `%y` and `%G`.
      YEARS = %w[Y y G].freeze

      # The letters of the directives that read a day of the month, `%d` and `%e`.
      DAYS = %w[d e].freeze

      # The letters of the directives that read a weekday, `%a`, `%A`, `%u` and `%w`, which an ISO 8601 week needs.
      WEEKDAYS = %w[a A u w].freeze

      # The start of a pattern of Ruby's strptime that reads a number, after which a directive before it that reads as
      # many digits as there are reads only its own number of them, see #checks.
      NUMERIC = /\A(?:\d|%[EO]?[CDdeFGgHIjkLlMmNQRrSsTUuVvWwXxYy\d])/

      # Parameters:
      #   pattern: [String]
      #     The pattern, such as "%d/%m/%Y", in the syntax of Python's strptime.
      #
      # Raises ArgumentError for a pattern that reads a day of the month without a year, or an ISO 8601 week without its
      # year, week and weekday, see #check_date.
      def initialize(pattern)
        read = expand(pattern)
        check_date(pattern, read.scan(DIRECTIVE).flatten.compact)
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

      # Returns [Date] the date of the text, whose parts #parts returned: as Ruby's strptime reads it when the parts give
      # its year, see #dated?, otherwise as Python's strptime gives it, see #default_date, such as 1900-07-01 for `07`
      # with `%m`, rather than in the year that it is read, which Ruby's strptime gives it.
      #
      # Raises `Date::Error` for a date that does not exist, such as February 30.
      def date(text, parts)
        dated?(parts) ? Date.strptime(text, @read) : default_date(parts)
      end

      # Returns [DateTime] the time of the text, whose parts #parts returned: as Ruby's strptime reads it when the parts
      # give its year, see #dated?, otherwise on the date that Python's strptime gives it, see #default_date, such as
      # 1900-01-01 09:30 for `09:30` with `%H:%M`, rather than on the day that it is read, which Ruby's strptime gives it.
      #
      # Raises `Date::Error` for a date that does not exist, such as February 30.
      def datetime(text, parts)
        return DateTime.strptime(text, @read) if dated?(parts)

        date    = default_date(parts)
        seconds = parts.fetch(:sec, 0) + parts.fetch(:sec_fraction, 0)
        DateTime.new(date.year, date.month, date.day, parts.fetch(:hour, 0), parts.fetch(:min, 0), seconds,
                     Rational(parts.fetch(:offset, 0), 86_400))
      end

      private

      # Raises ArgumentError, naming the pattern, when its directives, the letters of the supplied pattern of Ruby's
      # strptime that it expands to, see #expand, cannot read every date as Python's strptime reads it, rather than read
      # some in the year that they are read, as Ruby's strptime reads them, or raise for every value, as Python's does:
      # - A day of the month, `%d` or `%e`, without a year, `%Y`, `%y` or `%G`, such as `%m/%d`, which Python's strptime
      #   raises ValueError for from 3.15, since the year that it gives text without one, 1900, is not a leap year, so
      #   that February 29 cannot be read.
      # - An ISO 8601 week, see #check_week.
      def check_date(pattern, letters)
        if letters.intersect?(DAYS) && !letters.intersect?(YEARS)
          raise(ArgumentError, "the format #{pattern.inspect} reads a day of the month without a year, which cannot " \
                               "read February 29, as Python's strptime raises for it: add a year, such as %Y")
        end
        check_week(pattern, letters) if letters.include?("G") || letters.include?("V")
      end

      # Raises ArgumentError, naming the pattern, for the directives of an ISO 8601 week that Python's strptime raises
      # ValueError for: the year of a week, `%G`, with the day of the year, `%j`, or without the week, `%V`, and a
      # weekday, `%a`, `%A`, `%u` or `%w`, which give its date together, and the week without the year of the week.
      def check_week(pattern, letters)
        if letters.include?("j")
          raise(ArgumentError, "the format #{pattern.inspect} reads the day of the year, %j, with an ISO 8601 week, " \
                               "which Python's strptime raises for: read the year with %Y instead")
        end
        return if letters.include?("G") && letters.include?("V") && letters.intersect?(WEEKDAYS)

        raise(ArgumentError, "the format #{pattern.inspect} reads an ISO 8601 week without its year, %G, its week, %V, " \
                             "or a weekday, such as %u, which give its date together, as Python's strptime requires: " \
                             "add them, or read the year with %Y, and a week with %U or %W, instead")
      end

      # Returns [true|false] whether the parts give the year of the date, see YEAR_PARTS, so that Ruby's strptime reads
      # it as Python's does, rather than in the year that it is read: those of `%Y`, `%y` and `%s`, and of `%G`, which a
      # pattern reads only with the week and weekday that complete its date, see #check_date.
      def dated?(parts)
        YEAR_PARTS.any? { |part| parts.key?(part) }
      end

      # Returns [Date] the date of parts without a year, see #dated?, as Python's strptime gives it: the day of the year
      # of `%j`, counted from 1900-01-01, see DEFAULT_DATE, otherwise the first day of the month that they read, or of
      # January, of 1900, since a pattern reads a day of the month only with a year, see #check_date. A weekday or a
      # week, such as `%a` or `%U`, is ignored, as Python's strptime uses them only with a year.
      def default_date(parts)
        year, month, day = DEFAULT_DATE
        return Date.new(year, month, day) + (parts[:yday] - 1) if parts.key?(:yday)

        Date.new(year, parts.fetch(:mon, month), day)
      end

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
