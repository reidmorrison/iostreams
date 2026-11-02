# frozen_string_literal: true

module IOStreams
  module Parquet
    # A column of a Parquet file that is written: the Parquet type of a field of the schema, and the value of the field
    # in the form that the `parquet` gem writes it.
    #
    # The type of each field:
    #   "string"    string
    #   "integer"   int64
    #   "number"    decimal(38, decimals), or double with `floatNumber: true`, whose value is already rounded to its
    #               `decimals`, if any, by its field, as the field rounds the number that CSV writes, see
    #               `IOStreams::Schema::Field#round`. A number needs one of them, since a Parquet decimal has a fixed
    #               number of digits after its point.
    #   "boolean"   boolean
    #   "date"      date32
    #   "datetime"  timestamp_micros, adjusted to UTC, so the time read back is in UTC, and has whole microseconds.
    #   "time"      time_micros, not adjusted to UTC, holding the time of the clock of the value, as a schema writes it in
    #               a format of text, see `IOStreams::Schema::Field#render`, which is read back as a time of day in UTC,
    #               with whole microseconds, see `IOStreams::Parquet::Reader`.
    #   "duration"  string, holding its ISO 8601 text, such as `P1M2DT3H`, which a schema with the field reads back as an
    #               `ActiveSupport::Duration`, since the `parquet` gem has no interval type.
    #   "object"    string, holding the JSON text of the Hash, which a schema with the field reads back as the Hash.
    #   "array"     string, holding the JSON text of the Array, read back the same way.
    #   "list"      a list of the Parquet type of its `itemType`, as above, so that a list read back is the same Array,
    #               and each item is in its own Parquet type, as other tools, such as DuckDB, read it: a list of numbers
    #               is a list of decimal(38, decimals), or of double with `floatNumber: true`, and needs one of them, as
    #               a number does.
    #   "year"      int64.
    #   "yearmonth" string, holding its text, such as `2026-10`, since Parquet has no type of a month.
    #   "geopoint"  string, holding the text of its format, such as `90.5, 45.5`, or the JSON text of an array or an
    #               object.
    #
    # A field whose `constraints` are `required` cannot be null, unless it allows blank values, see `allowBlank` in
    # `IOStreams::Schema::Field`. A field of type "any" raises ArgumentError, since Parquet needs the type of every
    # column.
    class Column
      # The precision of a Parquet decimal: the most digits that a decimal of 16 bytes holds.
      PRECISION = 38

      # The range of the values of a Parquet int64.
      INT64 = (-(2**63)...(2**63))

      # Parameters:
      #   field: [IOStreams::Schema::Field]
      #     The field that the column holds, or the field of the items of a list, see
      #     `IOStreams::Schema::Field#item_field`.
      #
      # Raises ArgumentError when the field has no Parquet type, see above.
      def initialize(field)
        @field = field
        @items = Column.new(field.item_field) if field.type == "list"
        @type  = parquet_type
        freeze
      end

      # Returns [String|Symbol] the key of the value of this column in each record, the name of its field.
      def key
        @field.name
      end

      # Returns [Hash] the field of the schema of the `parquet` gem that describes this column.
      def descriptor
        {name: @field.name.to_s, **type_descriptor, nullable: !@field.value_required?}
      end

      # Returns the value, of the type of the field, see `IOStreams::Schema::Field#render`, in the form that the
      # `parquet` gem writes it: a number as it is, already rounded to the decimals of its field, see
      # `IOStreams::Schema::Field#round`, which for a decimal is its scale, since the gem drops the digits after it. A Date
      # is the Time at the start of its day in UTC, since the gem converts the text of a date at midnight in the time zone
      # of the process, which writes the day before east of UTC, and for a date before 1970 the day after west of UTC.
      # A time is a Time in UTC, since the gem only converts a Time itself, not a time that only acts as one, such as the
      # `ActiveSupport::TimeWithZone` of a Rails app. A time of day is the time of its clock as a Time in UTC, since the
      # gem writes the time of the clock of a Time, whatever its offset, and only a Time. A Hash or an Array, of an
      # object or an array field, is its JSON text, see `IOStreams::Schema::Field#render`. A double that is not finite,
      # such as NaN, is written as it is.
      #
      # Raises `IOStreams::Errors::InvalidValue` for a value that the column cannot hold: an integer outside the range
      # of an int64, or a decimal that is not finite, or that has more digits before its decimal point than its decimal
      # holds, so that the record that holds it raises, naming its field, rather than the gem, once it writes the row.
      def value(value)
        return value if value.nil?

        case @type
        when :list then value.map { |item| @items.value(item) }
        when :int64 then int64(value)
        when :decimal then decimal(value)
        when :date32 then Time.utc(value.year, value.month, value.day)
        when :timestamp_micros then value.getutc
        when :time_micros then Time.utc(2000, 1, 1, value.hour, value.min, value.sec + value.subsec)
        when :string then value.is_a?(String) ? value : @field.render(value, :text)
        # A double, and a boolean, as they are.
        else value
        end
      end

      protected

      # Returns [Hash] the Parquet type of the column, as the `parquet` gem describes it, see #descriptor, which an item
      # of a list has too, which can be null.
      def type_descriptor
        descriptor = {type: @type}
        descriptor.merge!(precision: PRECISION, scale: @field.decimals) if @type == :decimal
        descriptor[:timezone] = "UTC" if @type == :timestamp_micros
        descriptor[:item] = @items.type_descriptor.merge(nullable: true) if @type == :list
        descriptor
      end

      private

      def parquet_type
        case @field.type
        when "list" then :list
        when "string", "duration", "object", "array", "yearmonth", "geopoint" then :string
        when "integer", "year" then :int64
        when "number" then number_type
        when "boolean" then :boolean
        when "date" then :date32
        when "datetime" then :timestamp_micros
        when "time" then :time_micros
        else
          raise(ArgumentError, "Field #{@field.name.inspect}: a field of type #{@field.type.inspect} has no Parquet " \
                               "type, so give it the type of its values, such as \"string\" or \"integer\"")
        end
      end

      def number_type
        return :double if @field.float?

        decimals = @field.decimals
        unless decimals
          raise(ArgumentError, "Field #{@field.name.inspect}: a number written to Parquet needs `decimals`, the digits " \
                               "after its decimal point, for a decimal, or `floatNumber: true` for a double")
        end
        if decimals > PRECISION
          raise(ArgumentError, "Field #{@field.name.inspect}: a Parquet decimal holds at most #{PRECISION} decimals: " \
                               "#{decimals}")
        end

        :decimal
      end

      def int64(value)
        return value if INT64.cover?(value)

        invalid(value, "#{value.inspect} is outside the range of a Parquet int64")
      end

      def decimal(value)
        unless value.finite?
          invalid(value, "#{IOStreams::Schema::Field.special_text(value)} is not finite, so it cannot be written as a " \
                         "Parquet decimal")
        end

        return value if value.abs < 10**(PRECISION - @field.decimals)

        invalid(value, "#{@field.render(value, :text)} has more than #{PRECISION - @field.decimals} digits before its " \
                       "decimal point, which a Parquet decimal(#{PRECISION}, #{@field.decimals}) cannot hold")
      end

      # Raises `IOStreams::Errors::InvalidValue` for a value of the column that Parquet cannot hold, naming its field,
      # and holding the value, see `IOStreams::Errors::InvalidValue#value`, as a field raises for a value that is not of
      # its type.
      def invalid(value, problem)
        message = "Field #{@field.name.inspect}: #{problem}"
        raise(IOStreams::Errors::InvalidValue.new(message, field: @field.name, value: value))
      end
    end
  end
end
