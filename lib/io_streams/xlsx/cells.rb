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
    #   Number, of a time format       | a Time on 2000-01-01, in UTC, as a time of day, see `IOStreams::Schema::Field`
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
      #   a date and time          its time in UTC, such as "2026-01-02T09:30:00Z", with its milliseconds when it has any
      #   a time                   the time of its clock, such as "09:30:00", which Excel shows, as a `time` field writes it
      #   any other number         as the workbook holds it, such as "1001" or "12.5"
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

      # Returns the number of a cell of a number type, by the class of its number format.
      def self.number(text, style, base_date)
        days = days(text) if style
        return Float(text) unless days

        case style
        when :date then base_date + days.floor
        when :date_time then date_time(days, base_date)
        when :time then days < 1 ? time_of_day(days) : date_time(days, base_date)
        end
      rescue ArgumentError, ZeroDivisionError
        text
      end

      # Returns [String] the text of a cell of a number type, by the class of its number format, see .text.
      def self.number_text(text, style, base_date)
        days = days(text) if style
        return text unless days

        case style
        when :date then (base_date + days.floor).iso8601
        when :date_time then Schema::Field.any_text(date_time(days, base_date))
        when :time then time_of_day_field.render(time_of_day(days), :text)
        end
      rescue ArgumentError, ZeroDivisionError
        text
      end

      # Returns [Rational|nil] the days since the first day of the workbook of the text of a number, or nil for one
      # outside the dates that Excel holds, from its first day up to 9999-12-31, such as a negative number, or one of a
      # huge exponent, which is checked as a Float before it becomes a Rational, so that its cost is bounded.
      def self.days(text)
        days = Float(text)
        Rational(text) if days >= 0 && days < LAST_DAY
      end

      # Returns [IOStreams::Schema::Field] a field of type `time`, which writes the text of a time of day.
      def self.time_of_day_field
        @time_of_day_field ||= Schema::Field.new(name: "time", type: "time")
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
      private_class_method :number, :number_text, :days, :time_of_day_field, :date_time, :time_of_day, :seconds
    end
  end
end
