# frozen_string_literal: true

require "bigdecimal"
require "date"

module IOStreams
  class Schema
    # Drafts the type of each column of a source from a sample of its values, see `IOStreams::Stream#infer_schema`, as a
    # tool to run once, whose draft a person reviews and saves, never as a step of reading, since a guess changes with
    # the data, such as `007` in one file of a feed and `7` in the next. It never knows a format: it is given the records
    # of the sample, as `each(:hash)` reads them without a schema, text or typed values.
    #
    # Of the values of each column that are not blank, it drafts:
    #   integer:  whole numbers, such as `1001` or `-12`, but not text with a leading zero, such as `01234` or `007`,
    #             which stays a string.
    #   number:   numbers with a fraction, such as `12.50`, with the most `decimals` seen.
    #   boolean:  `true` or `false`, in any case.
    #   date, datetime and time: ISO 8601 text, such as `2026-10-25`, `2026-10-25T09:30:00Z` or `09:30:00`, or Dates and
    #             Times.
    #   date with a `format`: US dates, such as `10/25/2026`, see #us_date.
    #   object and array: Hashes and Arrays, such as those of JSON.
    #   string:   any other text, or text of several of these types, such as numbers and dates.
    #   any:      a column without a value in the sample, for a person to decide, or values of several types that are not
    #             all text.
    class Inference
      # A whole number without a leading zero, which `0` is not.
      INTEGER = /\A[+-]?(?:0|[1-9]\d*)\z/

      # A number with a fraction, whose whole part has no leading zero, such as `12.50`, `0.5` or `.5`.
      NUMBER = /\A[+-]?(?:0|[1-9]\d*)?\.(\d+)\z/

      # The text of a boolean that a field reads without `trueValues` or `falseValues`, other than `1` and `0`, which are
      # integers, see `IOStreams::Schema::Field::DEFAULT_TRUE_VALUES`.
      BOOLEANS = (Field::DEFAULT_TRUE_VALUES + Field::DEFAULT_FALSE_VALUES).to_h { |text| [text, true] }.freeze

      # A date written month or day first, such as `10/25/2026` or `25/10/2026`, see #us_date.
      SLASHED_DATE = %r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}

      # The values that `sample:` takes besides a positive Integer.
      ALL = :all

      # Raises ArgumentError for a `sample:` that is neither a positive Integer nor `:all`, see
      # `IOStreams::Stream#infer_schema`.
      def self.check_sample(sample)
        return if sample == ALL || (sample.is_a?(Integer) && sample.positive?)

        raise(ArgumentError, "sample: must be a positive Integer, the number of rows to read, or :all: #{sample.inspect}")
      end

      # Returns [Integer|Float] the number of records to read for the supplied `sample:`, see .check_sample.
      def self.size(sample)
        sample == ALL ? Float::INFINITY : sample
      end

      def initialize
        @columns = {}
      end

      # Returns [Array<String|Symbol>] the keys of the records added, in the order that they were first seen, such as
      # the keys of JSON records, which can vary from record to record.
      def names
        @columns.keys
      end

      # Adds the values of a record of the sample, by the names of their columns.
      def <<(record)
        record&.each_pair { |name, value| column(name) << value }
        self
      end

      # Returns [Array<Hash>] the descriptor of the field of each of the supplied columns, in order, see
      # `IOStreams::Schema::Field`, drafted from its values, see above: "any" for a column without values.
      def fields(names = self.names)
        names.map { |name| @columns.fetch(name) { Column.new }.field(name) }
      end

      private

      def column(name)
        @columns[name] ||= Column.new
      end

      # The values of one column of the sample, by the kind of each one, see #<<.
      class Column
        def initialize
          @kinds    = {}
          @decimals = 0
          @text        = true
          @us_date     = false
          @month_first = true
          @day_first   = true
        end

        # Adds the supplied value of the column.
        def <<(value)
          kind = kind_of(value)
          @kinds[kind] = true unless kind.nil?
        end

        # Returns [Hash] the descriptor of the field of the column, see `IOStreams::Schema::Field`.
        def field(name)
          field = {name: name, type: type}
          field[:decimals] = @decimals if field[:type] == "number"
          if field[:type] == "date" && @kinds.key?(:us_date)
            format, description = us_date
            field[:format]      = format
            field[:description] = description if description
          end
          field
        end

        private

        # Returns [String] the type of the column, from the kinds of its values.
        def type
          kinds = @kinds.keys
          return "any" if kinds.empty?
          return "number" if (kinds - %i[integer number]).empty? && kinds.include?(:number)
          return "date" if kinds == [:us_date] && us_date
          return kinds.first.to_s if kinds.size == 1 && kinds.first != :us_date && kinds.first != :text

          @text ? "string" : "any"
        end

        # Returns [Symbol|nil] the kind of the value, or nil when it is blank, which drafts nothing.
        def kind_of(value)
          return text_kind(value) if value.is_a?(String)
          return if value.nil?

          @text = false
          case value
          when true, false then :boolean
          when Integer then :integer
          when Float, Rational then float_kind(value)
          when ::Hash then :object
          when ::Array then :array
          when Time, DateTime then :datetime
          when Date then :date
          else decimal?(value) ? float_kind(value) : :text
          end
        end

        # Returns [Symbol|nil] the kind of the text of a value.
        def text_kind(text)
          text = text.strip
          return if text.empty?
          return :integer if INTEGER.match?(text)

          if (fraction = NUMBER.match(text))
            @decimals = [@decimals, fraction[1].length].max
            return :number
          end
          return :boolean if BOOLEANS.key?(text)
          return :date if iso?(text, Field::DATE)
          return :datetime if iso?(text, Field::DATETIME) && clock?(text[11, 8])
          return :time if Field::TIME.match?(text) && clock?(text)

          slashed_date(text) || :text
        end

        # Returns [Symbol] the kind of a number that is not text: an integer when it is whole, such as the Float that a
        # spreadsheet holds a whole number as, otherwise a number, counting the digits of its fraction.
        def float_kind(number)
          return :integer if number.finite? && number == number.floor

          digits = number.finite? ? BigDecimal(number.to_s).to_s("F").split(".").last.length : 0
          @decimals = [@decimals, digits].max
          :number
        rescue ArgumentError
          :number
        end

        def decimal?(value)
          value.is_a?(::BigDecimal)
        end

        # Returns [true|false] whether the text is an ISO 8601 date or datetime of a day that exists.
        def iso?(text, pattern)
          pattern.match?(text) && Date.valid_date?(text[0, 4].to_i, text[5, 2].to_i, text[8, 2].to_i)
        end

        def clock?(text)
          hour, minute, second = text[0, 8].split(":").map(&:to_i)
          hour < 24 && minute < 60 && second < 60
        end

        # Returns [:us_date|nil] the kind of a date written month or day first, such as `10/25/2026`, whose parts it keeps,
        # see #us_date, or nil when it is no date either way.
        def slashed_date(text)
          parts = SLASHED_DATE.match(text)
          return unless parts

          first, second, year = parts.captures.map(&:to_i)
          return unless Date.valid_date?(year, first, second) || Date.valid_date?(year, second, first)

          @month_first &&= Date.valid_date?(year, first, second)
          @day_first   &&= Date.valid_date?(year, second, first)
          :us_date
        end

        # Returns [Array(String, String|nil)] the strptime format of the dates written month or day first, see
        # #slashed_date, and a description for the person who reviews the draft when every one could be either: a part
        # above 12 settles which is the day. Every sampled date that could be either drafts month first, as the US writes
        # them. Returns nil when the dates disagree, such as one with a first part above 12 and another with a second.
        def us_date
          return ["%d/%m/%Y", nil] if @day_first && !@month_first
          return unless @month_first
          return ["%m/%d/%Y", nil] unless @day_first

          ["%m/%d/%Y", "Every sampled date could be month or day first, such as 01/02/2026, so month first was drafted: " \
                       "check it, and use %d/%m/%Y for day first"]
        end
      end
      private_constant :Column
    end
  end
end
