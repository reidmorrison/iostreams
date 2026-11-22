# frozen_string_literal: true

require "date"

module IOStreams
  module Xlsx
    # A date system of Excel: how a workbook numbers its days, so that a cell of a date or time holds the number of days
    # since the first day of the system, and the dates that a cell shows. A workbook uses one of two, see
    # `IOStreams::Xlsx::Book#date_system`:
    #
    # * The 1900 date system, of every workbook that Excel for Windows writes, and that IOStreams writes. Its day 1 is
    #   1900-01-01, and it counts 1900-02-29, day 60, which was not a day, as Lotus 1-2-3 did, so that from day 61,
    #   1900-03-01, each number is a day more than the days since 1899-12-31. Its day 0 is 1900-01-00, as Excel shows it,
    #   which is read as the day before 1900-01-01, and its day 60 as 1900-02-28, so that each date before 1900-03-01 is
    #   the one that Excel shows.
    # * The 1904 date system, of Excel for the Mac before 2011, whose day 0 is 1904-01-01.
    #
    # Each knows the dates that a cell shows, up to 9999-12-31, which IOStreams writes as cells of dates, see #holds?,
    # and reads from the number of a cell, see #days?.
    class DateSystem
      # The last date that Excel shows.
      LAST_DATE = Date.new(9999, 12, 31).freeze

      # The first time after the last date that Excel shows.
      AFTER_LAST_TIME = Time.utc(10_000, 1, 1).freeze

      # The Julian day of 1970-01-01, the first day of Unix time.
      UNIX_DAY = Date.new(1970, 1, 1).jd

      # The seconds of a day.
      DAY = 86_400.0

      # Parameters
      #   zero: [Date]
      #     The date of the day whose number is 0, which is a day earlier before the leap day of the 1900 date system.
      #
      #   leap_day: [Integer|nil]
      #     The number of the day that the date system counts, which was not a day, 60, 1900-02-29, or nil for none.
      def initialize(zero:, leap_day: nil)
        @zero       = zero
        @leap_day   = leap_day
        @first_date = (leap_day ? date(1) : zero).freeze
        @first_time = Time.utc(@first_date.year, @first_date.month, @first_date.day).freeze
        @after_last = day(LAST_DATE) + 1
        @unix_days  = zero.jd - UNIX_DAY
        freeze
      end

      # Returns [true|false] whether the date system is that of 1904, which the workbook part records as `date1904`.
      def date1904?
        @leap_day.nil?
      end

      # Returns [Date] the date of the number of a day, as Excel shows it, see the class.
      def date(day)
        @leap_day && day < @leap_day ? @zero + day + 1 : @zero + day
      end

      # Returns [Integer] the number of the day of a date, the inverse of #date.
      def day(date)
        day = date.jd - @zero.jd
        @leap_day && day <= @leap_day ? day - 1 : day
      end

      # Returns [Float] the number of days of the clock of a time, in its own offset, with the fraction of its day, as a
      # cell of a date and time holds it.
      def days(time)
        days = ((time.to_f + time.utc_offset) / DAY) - @unix_days
        @leap_day && days < @leap_day + 1 ? days - 1 : days
      end

      # Returns [true|false] whether a number of days is one that the date system shows as a date: from 0, also of a
      # time of day, to the end of the last day, 9999-12-31, such as neither a negative number, which Excel shows as
      # `####`, nor a huge one.
      def days?(days)
        days >= 0 && days < @after_last
      end

      # Returns [true|false] whether a cell holds the date, or the date and time in UTC, as one that Excel shows: from
      # the first date of the date system, 1900-01-01, to the last day of the year 9999. Excel shows the day 0 of the
      # 1900 date system as 1900-01-00, which is no date, and a negative number as `####`, while a cell of a number of
      # less than 1 is a time of day. A time is compared to the millisecond that a cell holds, so that one within half a
      # millisecond of the year 10000 is not held, rather than a cell that holds the year 10000.
      def holds?(value)
        if value.is_a?(Time)
          value = value.round(3)
          value >= @first_time && value < AFTER_LAST_TIME
        else
          value.between?(@first_date, LAST_DATE)
        end
      end

      SYSTEM_1900 = new(zero: Date.new(1899, 12, 30).freeze, leap_day: 60)
      SYSTEM_1904 = new(zero: Date.new(1904, 1, 1).freeze)
    end
  end
end
