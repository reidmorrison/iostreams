# frozen_string_literal: true

require "date"

module IOStreams
  module Xlsx
    # The class of the number format of each cell of a worksheet, from Excel's own number formats, and the text of a cell
    # of a date or a time, as IOStreams 3.0 types them, so that a spreadsheet read with a schema, see
    # `IOStreams::Xlsx::SchemaReader`, holds the same dates and times in IOStreams 2.2 and 3.0, rather than as creek
    # classifies them, which takes every custom format with a letter of a date or a time as a date and time, such as
    # `yyyy-mm-dd`, or `0.00" days"`:
    #
    #   Number format            | Text of the cell
    #   a date                   | its date in ISO 8601, such as `2026-10-25`
    #   a date and time          | the time of its clock in UTC, such as `2026-10-25T09:30:00Z`, since Excel has no zone
    #   a time of day            | the time of its clock, such as `09:30:00`
    module Cells
      # The seconds of a day.
      DAY = 86_400

      # The first day of a time of day, as Active Record holds the value of a `time` column.
      TIME_OF_DAY = [2000, 1, 1].freeze

      # The number of the day after the last date that Excel holds, 9999-12-31, since 1899-12-30.
      LAST_DAY = 2_958_466

      # The built-in number formats of Excel of dates, times of day, and dates with times, by their ids.
      BUILT_IN_FORMATS = {
        14 => :date, 15 => :date, 16 => :date, 17 => :date, 18 => :time, 19 => :time, 20 => :time, 21 => :time,
        22 => :date_time, 45 => :time, 46 => :time, 47 => :time
      }.freeze

      # The parts of a custom format code that are not its tokens: quoted text, an escaped character, and a section in
      # brackets other than an elapsed time, such as a color or a locale. A section never holds another `[`, so a match
      # stops there, rather than scan the rest of the code again from each `[` of a workbook's code that never closes.
      LITERALS = /"[^"]*"|\\.|_.|\*.|\[(?![hms]+\])[^\[\]]*\]/i

      # Returns [Array<Symbol|nil>] the class of the number format of each style of a workbook, by the index of the style,
      # as a cell names it with its `s` attribute: `:date`, `:time` or `:date_time`, or nil for a number, from Excel's own
      # number formats, see BUILT_IN_FORMATS and .custom_format, rather than as creek finds them.
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

      # Returns [Symbol|nil] the class of a custom format code, by the first of its sections: `:date` with only a year,
      # month or day, `:time` with only hours, minutes or seconds, `:date_time` with both, otherwise nil, for a number.
      # An `m` is minutes after hours or before seconds, otherwise the month.
      def self.custom_format(code)
        tokens = code.split(";").first.to_s.gsub(LITERALS, "")
        time   = tokens.match?(%r{[hs]|am/pm|a/p}i)
        date   = tokens.match?(/[yd]/i) || (!time && tokens.match?(/m/i))
        if date && time then :date_time
        elsif date then :date
        elsif time then :time
        end
      end

      # Returns [String|nil] the text of a cell of a number type, the text of its `<v>` element, by the class of its
      # number format, see .number_formats, with the first day of the workbook, see `Creek::Sheet#converter_options`, as
      # IOStreams 3.0 types it, so that a field of its type reads it:
      #   a date                   in ISO 8601, such as "2026-10-25"
      #   a date and time          its time in UTC, such as "2026-10-25T09:30:00Z", with its milliseconds when it has any
      #   a time                   the time of its clock, such as "09:30:00", or of a number of a day or more, its date
      #                            and time, as a date and time
      #
      # Returns nil for a number of any other format, or one of a date or time format that is not a date that Excel
      # holds, such as a negative number, which Excel shows as `####`, which is a number.
      def self.date_text(text, style, base_date)
        days = days(text) if style
        return unless days

        case style
        when :date then (base_date + days.floor).iso8601
        when :date_time then Schema::Field.any_text(date_time(days, base_date))
        when :time then days < 1 ? time_of_day_text(time_of_day(days)) : Schema::Field.any_text(date_time(days, base_date))
        end
      rescue ArgumentError, ZeroDivisionError
        nil
      end

      # Returns [Rational|nil] the days since the first day of the workbook of the text of a number, or nil for one
      # outside the dates that Excel holds, from its first day up to 9999-12-31, such as a negative number, or one of a
      # huge exponent, which is checked as a Float before it becomes a Rational, so that its cost is bounded.
      def self.days(text)
        days = Float(text)
        Rational(text) if days >= 0 && days < LAST_DAY
      end

      # Returns [String] the time of the clock of a time of day, such as "09:30:00", with the milliseconds that Excel
      # holds when it has any, such as "09:30:00.500", as a `time` field of IOStreams 3.0 writes it.
      def self.time_of_day_text(time)
        time.nsec.zero? ? time.strftime("%H:%M:%S") : time.strftime("%H:%M:%S.%3N")
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
      private_class_method :days, :time_of_day_text, :date_time, :time_of_day, :seconds
    end
  end
end
