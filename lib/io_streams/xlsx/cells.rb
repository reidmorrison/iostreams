# frozen_string_literal: true

require "date"

module IOStreams
  module Xlsx
    # The value of each cell of a worksheet, typed by Excel's own cell type and number format, so that the gem that reads
    # the workbook, creek, is only its reader, and another could replace it once it exposes the same:
    #
    #   Excel cell                     | Ruby value
    #   Text                           | a String, keeping `01234`
    #   Number, without a date format  | a Float, as Excel stores it
    #   Number, of a date format       | a Date
    #   Number, of a date and time     | a Time, in UTC, with the time of the clock of the cell, since Excel has no zone
    #   Number, of a time format       | a Time on 2000-01-01, in UTC, as a time of day, see `IOStreams::Schema::Field`,
    #                                  | or of a day or more, a date and time, as above, also of an elapsed time
    #   Boolean                        | true or false
    #   Empty                          | nil
    #   Error, such as #N/A            | nil
    #   Formula                        | its cached value, typed as above
    #
    # A whole number is a Float, such as `1001.0`: a contract's `integer` field converts it, and raises for `1001.5`.
    #
    # The CSV text of a worksheet, its lines, holds the text of each cell as .text gives it, so that the lines and the
    # rows of a workbook agree on which cells hold a date or a time.
    module Cells
      # The seconds of a day.
      DAY = 86_400

      # The first day of a time of day, as Active Record holds the value of a `time` column.
      TIME_OF_DAY = [2000, 1, 1].freeze

      # The number of the day after the last date that Excel holds, 9999-12-31, since 1899-12-30.
      LAST_DAY = 2_958_466

      # The built-in number formats of Excel of dates, times of day, elapsed times, and dates with times, by their ids.
      BUILT_IN_FORMATS = {
        14 => :date, 15 => :date, 16 => :date, 17 => :date, 18 => :time, 19 => :time, 20 => :time, 21 => :time,
        22 => :date_time, 45 => :time, 46 => :elapsed, 47 => :time
      }.freeze

      # The classes of the number formats of a time, see .number_formats: of a time of day, whose clock Excel shows, and
      # of an elapsed time, whose hours Excel shows, such as `36:00:00` for a day and a half.
      TIME_FORMATS = %i[time elapsed].freeze

      # The part of a custom format code that shows an elapsed time, such as `[h]` or `[mm]`.
      ELAPSED = /\[[hms]+\]/i

      # The most significant digits that Excel displays of a number, see .displayed.
      DISPLAYED_DIGITS = 15

      # The whole numbers that a Float holds exactly, below 2**53, which keep every digit, see .displayed.
      EXACT_WHOLE = 2**53

      # The parts of a custom format code that are not its tokens: quoted text, an escaped character, and a section in
      # brackets other than an elapsed time, such as a color or a locale. A section never holds another `[`, so a match
      # stops there, rather than scan the rest of the code again from each `[` of a workbook's code that never closes.
      LITERALS = /"[^"]*"|\\.|_.|\*.|\[(?![hms]+\])[^\[\]]*\]/i

      # A field of type `time`, which writes the text of a time of day.
      TIME_OF_DAY_FIELD = Utils.shareable(Schema::Field.new({name: "time", type: "time"}))
      private_constant :TIME_OF_DAY_FIELD

      # Returns [Array<Symbol|nil>] the class of the number format of each style of a workbook, by the index of the style,
      # as a cell names it with its `s` attribute: `:date`, `:time`, `:elapsed` or `:date_time`, or nil for a number,
      # from Excel's own number formats, see BUILT_IN_FORMATS and .custom_format, rather than as creek finds them.
      #
      # Parameters:
      #   styles: [Nokogiri::XML::Document|nil]
      #     The styles of the workbook, `xl/styles.xml`, or nil for a workbook without them.
      def self.number_formats(styles)
        return [] if styles.nil?

        custom = styles.css("styleSheet numFmts numFmt").to_h do |format|
          [format["numFmtId"].to_i, custom_format(format["formatCode"].to_s)]
        end
        styles.css("styleSheet cellXfs xf").map do |style|
          id = style["numFmtId"]&.to_i
          BUILT_IN_FORMATS.fetch(id) { custom[id] } if id
        end
      end

      # Returns [BigDecimal] the number of a finite Float that a cell holds, to the digits that Excel displays, its most
      # significant 15, such as `0.3` for `0.30000000000000004`, apart from a whole number below 2**53, which a Float
      # holds exactly, which keeps every digit, such as the card number `4111111111111111`, which a field that keeps the
      # digits of its numbers reads, see `IOStreams::Xlsx::Reader::Rows`.
      #
      # The exact value of the Float is rounded half up, to the digits counted from the first significant digit of its
      # shortest text, rather than that text, so that the digits are the same on every Ruby, since JRuby writes the text
      # of some Floats with other digits than MRI does. Rounded so, the number has at most one more digit than Excel
      # displays, which the BigDecimal holds exactly.
      def self.displayed(number)
        return BigDecimal(number.to_i) if number == number.truncate && number.abs < EXACT_WHOLE

        digits = DISPLAYED_DIGITS - BigDecimal(number.to_s).exponent
        BigDecimal(number.to_r.round(digits, half: :up), DISPLAYED_DIGITS + 1)
      end

      # Returns [String] the text of a finite Float that a cell holds, to the digits that Excel displays, see .displayed,
      # in plain digits, without a decimal point for a whole number, such as "2134" for `2134.0`, "0.3" for
      # `0.30000000000000004`, or "0.0000001" for `1e-7`, as the CSV text of the cell holds it, see .text, and a
      # `string` field reads it.
      def self.displayed_text(number)
        return number.to_i.to_s if number.abs < EXACT_WHOLE && number == number.truncate

        number = displayed(number)
        number.frac.zero? ? number.to_i.to_s : number.to_s("F")
      end

      # Returns [Symbol|nil] the class of a custom format code, by the first of its sections: `:date` with only a year,
      # month or day, `:time` with only hours, minutes or seconds, `:elapsed` with an elapsed time, such as `[h]:mm:ss`,
      # `:date_time` with a date and a time, otherwise nil, for a number. An `m` is minutes after hours or before seconds,
      # or within brackets, otherwise the month.
      def self.custom_format(code)
        tokens  = code.split(";").first.to_s.gsub(LITERALS, "")
        elapsed = tokens.match?(ELAPSED)
        time    = elapsed || tokens.match?(%r{[hs]|am/pm|a/p}i)
        date    = tokens.match?(/[yd]/i) || (!time && tokens.match?(/m/i))
        if date && time then :date_time
        elsif date then :date
        elsif elapsed then :elapsed
        elsif time then :time
        end
      end

      # Returns the value of a cell of the supplied text of its `<v>` or `<t>` element, cell type, its `t` attribute,
      # and the class of its number format, see .number_formats, such as `:date`, with the shared strings and the first
      # day of the workbook, see `Creek::Sheet#converter_options`.
      def self.value(text, type, style, options)
        return if text.nil? || text.empty?

        case type
        when "s" then options[:shared_strings][text.to_i]
        when "str", "inlineStr" then Creek::Styles::Converter.unescape_string(text)
        when "b" then text == "1" || text.casecmp?("true")
        when "e" then nil
        else number(text, style, options[:base_date])
        end
      end

      # Returns [String|nil] the text of a cell, as the CSV text of a worksheet holds it, see
      # `IOStreams::Xlsx::Reader#each`, from the same classes of number formats as .value, so that the lines and the rows
      # of a workbook agree on which cells hold a date or a time. Excel holds a date or a time without a time zone, so
      # its text is the same in every process, and a field of its type reads it:
      #   a date                   in ISO 8601, such as "2026-01-02"
      #   a date and time          its clock, without an offset, such as "2026-01-02T09:30:00", with its milliseconds when
      #                            it has any, which a field reads in its `timeZone`, or in UTC without one, as the cell
      #   a time                   the time of its clock, such as "09:30:00", which Excel shows, as a `time` field writes it
      #   an elapsed time          the time of its clock below a day, otherwise the clock of the date and time that .value
      #                            reads, such as "1899-12-31T12:00:00" for `36:00:00` of the format `[h]:mm:ss`
      #   any other number         to the digits that Excel displays, see .displayed_text, such as "1001", "12.5", or
      #                            "0.3" for the 0.30000000000000004 that the workbook holds
      #   text                     as it is
      #   a boolean                "true" or "false"
      #   an error, such as #N/A   as Excel shows it
      #   an empty cell            nil
      #
      # A number of a date or time format that is not a date that Excel holds, such as a negative number, which Excel
      # shows as `####`, is a number.
      #
      # Parameters are those of .value.
      def self.text(text, type, style, options)
        return if text.nil? || text.empty?
        return number_text(text, style, options[:base_date]) if type.nil? || type == "n"
        return text if type == "e"

        value(text, type, style, options).to_s
      end

      # Returns [String|nil] the time of the clock of a cell of a time of day, a number of a time format of less than a
      # day, such as "09:30:00", as .text gives it, which .value reads as a Time on 2000-01-01, see .time_of_day, so that
      # a `string` field reads the same text from the rows as from the lines, as IOStreams 2.2 reads it. Returns nil for
      # any other cell, including one of a time format of a day or more, which is a date and time.
      #
      # Parameters are those of .value, without its options.
      def self.clock(text, type, style)
        return unless TIME_FORMATS.include?(style) && (type.nil? || type == "n") && text && !text.empty?

        days = days(text)
        TIME_OF_DAY_FIELD.render(time_of_day(days), :text) if days && days < 1
      rescue ArgumentError, ZeroDivisionError
        nil
      end

      # Returns [String|nil] the ISO 8601 text of the length of time of a cell of a time format, or of an elapsed time,
      # see TIME_FORMATS, such as `PT1H30M` for `1:30:00`, or `PT36H` for `36:00:00`, to the millisecond that Excel
      # holds, which a `duration` field reads, see `IOStreams::Schema::Field#time_cell`, or nil for any other cell, such
      # as a number, which does not say what it counts, or a number of a time format that is not a date that Excel holds,
      # such as a negative one.
      #
      # Parameters are those of .value, without its options.
      def self.length(text, type, style)
        return unless TIME_FORMATS.include?(style) && (type.nil? || type == "n") && text && !text.empty?

        days = days(text)
        duration_text((days * DAY).round(3)) if days
      rescue ArgumentError, ZeroDivisionError
        nil
      end

      # Returns [String] the ISO 8601 text of a length of time of the supplied seconds, in hours, minutes and seconds,
      # such as `PT36H`, `PT1H30M` or `PT0.5S`, see .length.
      def self.duration_text(seconds)
        hours, seconds   = seconds.divmod(3600)
        minutes, seconds = seconds.divmod(60)
        parts = []
        parts << "#{hours}H" unless hours.zero?
        parts << "#{minutes}M" unless minutes.zero?
        parts << "#{seconds.denominator == 1 ? seconds.to_i : seconds.to_f}S" unless seconds.zero? && !parts.empty?
        "PT#{parts.join}"
      end

      # Returns the number of a cell of a number type, by the class of its number format.
      def self.number(text, style, base_date)
        days = days(text) if style
        return Float(text) unless days

        case style
        when :date then base_date + days.floor
        when :date_time then date_time(days, base_date)
        when :time, :elapsed then days < 1 ? time_of_day(days) : date_time(days, base_date)
        end
      rescue ArgumentError, ZeroDivisionError
        text
      end

      # Returns [String] the text of a cell of a number type, by the class of its number format, see .text.
      def self.number_text(text, style, base_date)
        days = days(text) if style
        return plain_text(text) unless days

        return elapsed_text(days, base_date) if style == :elapsed

        case style
        when :date then (base_date + days.floor).iso8601
        when :date_time then Schema::Field.clock_text(date_time(days, base_date))
        when :time then TIME_OF_DAY_FIELD.render(time_of_day(days), :text)
        end
      rescue ArgumentError, ZeroDivisionError
        text
      end

      # Returns [String] the text of a number that is not a date or a time, to the digits that Excel displays, see
      # .displayed_text, or the text itself for one that is not finite, such as `1e10000`.
      def self.plain_text(text)
        number = Float(text)
        number.finite? ? displayed_text(number) : text
      end

      # Returns [String] the text of a cell of an elapsed time, see .text: the time of its clock below a day, otherwise
      # the date and time that .value reads, rather than the time of its clock without its days, which Excel does not
      # show for an elapsed time.
      def self.elapsed_text(days, base_date)
        return TIME_OF_DAY_FIELD.render(time_of_day(days), :text) if days < 1

        Schema::Field.clock_text(date_time(days, base_date))
      end

      # Returns [Rational|nil] the days since the first day of the workbook of the text of a number, or nil for one
      # outside the dates that Excel holds, from its first day up to 9999-12-31, such as a negative number, or one of a
      # huge exponent, which is checked as a Float before it becomes a Rational, so that its cost is bounded.
      def self.days(text)
        days = Float(text)
        Rational(text) if days >= 0 && days < LAST_DAY
      end

      # Returns [Time] the time, in UTC, of the clock of the days since the first day of the workbook, to the millisecond
      # that Excel holds.
      def self.date_time(days, base_date)
        date = base_date + days.floor
        Time.utc(date.year, date.month, date.day) + seconds(days)
      end

      # Returns [Time] the time of day of the fraction of a day, on 2000-01-01 in UTC, also when the fraction rounds to
      # a whole day, which is midnight.
      def self.time_of_day(days)
        Time.utc(*TIME_OF_DAY) + (seconds(days) % DAY)
      end

      # Returns [Rational] the seconds of the fraction of the day, to the millisecond.
      def self.seconds(days)
        ((days - days.floor) * DAY).round(3)
      end
      private_class_method :number, :number_text, :plain_text, :elapsed_text, :duration_text, :days, :date_time,
                           :time_of_day, :seconds
    end
  end
end
