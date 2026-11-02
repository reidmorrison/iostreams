# frozen_string_literal: true

require "date"

module IOStreams
  class Schema
    # The pattern of the text of a date or datetime field, its `format`, which Frictionless writes in the syntax of
    # Python and C's strptime, see https://datapackage.org/standard/table-schema/, and which IOStreams reads and writes
    # with Ruby's strptime and strftime, whose directives are mostly the same:
    #   %Y  the year in exactly 4 digits, as Python reads it, such as "2026", where Ruby reads as many digits as there
    #       are, so that "26" would be the year 26.
    #   %f  the microseconds, which Ruby does not have: 1 to 6 digits of the fraction of a second when reading, such as
    #       "5" for half a second, and 6 digits when writing, such as "500000".
    #
    # Every other directive is Ruby's, which reads and writes the directives of Python the same way. Ruby's own
    # directives, such as `%N`, `%L` and `%s`, still work, but other Frictionless tools do not read them.
    class Pattern
      # A directive of a pattern: `%%`, or `%` with its flags, width and letter, such as `%d`, `%-m` or `%:z`, whose
      # letter is captured. A width does not start with `0`, which is a flag, so that the flags and the width never match
      # the same characters, which would take time that grows with the square of their length.
      DIRECTIVE = /%(?:%|[-_0^#:]*(?:[1-9]\d*)?([a-zA-Z+]))/

      # The directive of Python's microseconds, which Ruby does not have, and Ruby's directives that read and write it.
      MICROSECONDS = "%f"
      READ_MICROSECONDS  = "%N"
      WRITE_MICROSECONDS = "%6N"

      # The directives whose digits Ruby counts differently than Python, and the digits that Python reads for each one.
      DIGITS = {"%Y" => "\\d{4}", MICROSECONDS => "\\d{1,6}"}.freeze

      # The letters of the directives that write a zone, see #zone?.
      ZONES = %w[z Z +].freeze

      # The start of a pattern of Ruby's strptime that reads a number, after which a directive before it that reads as
      # many digits as there are reads only its own number of them, see #checks.
      NUMERIC = /\A(?:\d|%[EO]?[CDdeFGgHIjkLlMmNQRrSsTUuVvWwXxYy\d])/

      # Parameters:
      #   pattern: [String]
      #     The pattern, such as "%d/%m/%Y", in the syntax of Python's strptime.
      def initialize(pattern)
        @write  = -ruby(pattern, WRITE_MICROSECONDS)
        @read   = -ruby(pattern, READ_MICROSECONDS)
        @checks = checks(pattern).freeze
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
      # Returns nil when the pattern does not match all of the text, or a year does not have exactly 4 digits, or
      # microseconds 1 to 6, as Python reads them.
      def parts(text)
        parts = Date._strptime(text, @read)
        return if parts.nil? || parts.key?(:leftover)

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

      # Returns [String] the pattern of Ruby's strptime or strftime of the pattern of Python, whose microseconds are the
      # supplied directive of Ruby, see MICROSECONDS.
      def ruby(pattern, microseconds)
        pattern.gsub(DIRECTIVE) { |directive| directive == MICROSECONDS ? microseconds : directive }
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

          after  = NUMERIC.match?(ruby(match.post_match, READ_MICROSECONDS)) ? "" : "(?!\\d)"
          checks << [-ruby(match.pre_match, READ_MICROSECONDS), Regexp.new("\\G#{digits}#{after}")]
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
