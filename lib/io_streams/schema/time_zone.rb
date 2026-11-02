# frozen_string_literal: true

module IOStreams
  class Schema
    # The time zone of the text of a `datetime` or `time` field without an offset from UTC, its `timeZone`, which
    # IOStreams adds to the properties of Frictionless, see `IOStreams::Schema::Field`:
    #   "UTC"               the default.
    #   "+05:00", "-05:00"  a fixed offset from UTC.
    #   "America/New_York"  a zone of the IANA time zone database, through the tzinfo gem, which it requires only for
    #                       such a name, so that its offset is that of the time read, in summer or in winter.
    #
    # It reads the clock of text without an offset as a time in its zone, and gives the time that a field writes with a
    # format without a zone in its zone, so that it reads back as the same time.
    class TimeZone
      # A clock that the zone skips, such as 02:30 when its clocks move forward an hour, which is no time there, see
      # #at_clock.
      class SkippedClock < ArgumentError
      end

      # A fixed offset from UTC, its sign, hours and minutes.
      OFFSET = /\A([+-])(\d{2}):(\d{2})\z/

      # Parameters:
      #   name: [String]
      #     The zone, see above.
      #
      #   field: [String|Symbol]
      #     The name of the field, for the message of an error.
      #
      # Raises ArgumentError for a zone that is not one of those above, such as a name that the IANA time zone database
      # does not have, or that needs the tzinfo gem when it is not installed.
      def initialize(name, field)
        @name   = name
        @offset = fixed_offset(name, field)
        @zone   = named_zone(name, field) if @offset.nil?
        freeze
      end

      # Returns [Time] the time whose clock, its date and time of day, is that of the supplied time, read in this zone,
      # such as 09:30 in New York for a time of 09:30 in UTC.
      #
      # Raises `SkippedClock` for a clock that the zone skips, such as 02:30 when its clocks move forward an hour, which
      # is no time there. Of a clock that the zone has twice, as its clocks move back, it is the first.
      #
      # The clock can be moved to another day, such as to 2000-01-01 for a time of day, see `IOStreams::Schema::Field`,
      # whose offset is that of the zone on that day.
      def at_clock(time, year = time.year, month = time.month, day = time.day)
        seconds = time.sec + time.subsec
        return Time.utc(year, month, day, time.hour, time.min, seconds) if @offset&.zero?

        offset = @offset
        offset ||= local_offset(same_day?(time, year, month, day) ? time : Time.utc(year, month, day, time.hour, time.min))
        Time.new(year, month, day, time.hour, time.min, seconds, offset)
      end

      # Returns [Time] the time in this zone, at its offset from UTC at that time, which a field writes with a format
      # without a zone, see #at_clock.
      def convert(time)
        return time.getutc if @offset&.zero?

        time.getlocal(@offset || @zone.period_for_utc(time.getutc).utc_total_offset)
      end

      private

      # Returns [true|false] whether the time is on the supplied day, so that its offset is found from it as it is.
      def same_day?(time, year, month, day)
        year == time.year && month == time.month && day == time.day
      end

      # Returns [Integer|nil] the seconds of a fixed offset from UTC, 0 for "UTC", or nil for the name of a zone.
      #
      # Raises ArgumentError for an offset of more than 23 hours, or 59 minutes, which no zone has.
      def fixed_offset(name, field)
        return 0 if name == "UTC"
        unless name.is_a?(String) && !name.empty?
          raise(ArgumentError, "Field #{field.inspect}: timeZone must be \"UTC\", an offset such as \"+05:00\", or the name " \
                               "of a zone, such as \"America/New_York\": #{name.inspect}")
        end

        match = OFFSET.match(name)
        return unless match

        hours   = match[2].to_i
        minutes = match[3].to_i
        unless hours <= 23 && minutes < 60
          raise(ArgumentError, "Field #{field.inspect}: the timeZone #{name.inspect} is not an offset from UTC, whose hours " \
                               "are at most 23 and minutes at most 59")
        end

        seconds = (hours * 3600) + (minutes * 60)
        match[1] == "-" ? -seconds : seconds
      end

      # Returns [TZInfo::Timezone] the zone of the IANA time zone database of the name.
      def named_zone(name, field)
        require_tzinfo(name, field)
        begin
          TZInfo::Timezone.get(name)
        rescue TZInfo::InvalidTimezoneIdentifier
          raise(ArgumentError, "Field #{field.inspect}: the timeZone #{name.inspect} is not a zone of the IANA time zone " \
                               "database, such as \"America/New_York\", nor an offset, such as \"-05:00\"")
        rescue TZInfo::DataSourceNotFound => e
          raise(ArgumentError, "Field #{field.inspect}: the timeZone #{name.inspect} needs the IANA time zone database, " \
                               "which this system does not have, such as on Windows or in a slim container image, so add " \
                               "`gem \"tzinfo-data\"` to the Gemfile, or use an offset, such as \"-05:00\": #{e.message}")
        end
      end

      # Loads the tzinfo gem, which IOStreams does not depend on, since only the name of a zone needs it.
      #
      # Raises ArgumentError when it is not installed.
      def require_tzinfo(name, field)
        require "tzinfo"
      rescue LoadError => e
        raise(ArgumentError, "Field #{field.inspect}: the timeZone #{name.inspect} needs the tzinfo gem, so add " \
                             "`gem \"tzinfo\"` to the Gemfile, or use an offset, such as \"-05:00\": #{e.message}")
      end

      # Returns [Integer] the seconds of the offset from UTC of the zone at the clock of the time, whose own offset is
      # ignored, the first of the two of a clock that the zone has twice, as its clocks move back, whether or not
      # either is summer time, such as when a zone changed its offset for good.
      #
      # Raises `SkippedClock` for a clock that the zone skips, see #at_clock.
      def local_offset(time)
        @zone.period_for_local(time, nil, &:first).utc_total_offset
      rescue TZInfo::PeriodNotFound
        raise(SkippedClock, "#{time.strftime('%Y-%m-%d %H:%M:%S')} is no time in #{@name}, whose clocks skip it")
      end
    end
  end
end
