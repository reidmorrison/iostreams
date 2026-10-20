# frozen_string_literal: true

module IOStreams
  module Parquet
    # A column of a Parquet file that is written: the Parquet type of a field of the schema, and the value of the field
    # in the form that the `parquet` gem writes it.
    #
    # The type of each field:
    #   "string"    string
    #   "integer"   int64
    #   "number"    decimal(38, decimals), or double with `floatNumber: true`, whose value is rounded to its `decimals`, if
    #               any, as the field rounds the number that CSV writes, see `IOStreams::Schema::Field#round`. A number
    #               needs one of them, since a Parquet decimal has a fixed number of digits after its point.
    #   "boolean"   boolean
    #   "date"      date32
    #   "datetime"  timestamp_micros, adjusted to UTC, so the time read back is in UTC, and has whole microseconds.
    #   "object"    string, holding the JSON text of the Hash, which a schema with the field reads back as the Hash.
    #   "array"     string, holding the JSON text of the Array, read back the same way.
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
      #     The field that the column holds.
      #
      # Raises ArgumentError when the field has no Parquet type, see above.
      def initialize(field)
        @field = field
        @type  = parquet_type
        freeze
      end

      # Returns [String|Symbol] the key of the value of this column in each record, the name of its field.
      def key
        @field.name
      end

      # Returns [Hash] the field of the schema of the `parquet` gem that describes this column.
      def descriptor
        descriptor = {name: @field.name.to_s, type: @type, nullable: !@field.value_required?}
        descriptor.merge!(precision: PRECISION, scale: @field.decimals) if @type == :decimal
        descriptor[:timezone] = "UTC" if @type == :timestamp_micros
        descriptor
      end

      # Returns the value, of the type of the field, see `IOStreams::Schema::Field#render`, in the form that the
      # `parquet` gem writes it: a number rounded to the decimals of its field, as the field rounds it, see
      # `IOStreams::Schema::Field#round`, which for a decimal is its scale, since the gem drops the digits after it. A Date
      # is the Time at the start of its day in UTC, since the gem converts the text of a date at midnight in the time zone
      # of the process, which writes the day before east of UTC, and for a date before 1970 the day after west of UTC.
      # A time is a Time in UTC, since the gem only converts a Time itself, not a time that only acts as one, such as the
      # `ActiveSupport::TimeWithZone` of a Rails app. A Hash or an Array, of an object or an array field, is its JSON
      # text, see `IOStreams::Schema::Field#render`. A double that is not finite, such as NaN, is written as it is.
      #
      # Raises `IOStreams::Errors::InvalidValue` for a value that the column cannot hold: an integer outside the range
      # of an int64, or a decimal that is not finite, or that has more digits before its decimal point than its decimal
      # holds, so that the record that holds it raises, naming its field, rather than the gem, once it writes the row.
      def value(value)
        return value if value.nil?

        case @type
        when :int64 then int64(value)
        when :decimal then decimal(value)
        when :double then @field.round(value)
        when :date32 then Time.utc(value.year, value.month, value.day)
        when :timestamp_micros then value.getutc
        when :string then value.is_a?(String) ? value : @field.render(value, :text)
        else value
        end
      end

      private

      def parquet_type
        case @field.type
        when "string", "object", "array" then :string
        when "integer" then :int64
        when "number" then number_type
        when "boolean" then :boolean
        when "date" then :date32
        when "datetime" then :timestamp_micros
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

        raise(IOStreams::Errors::InvalidValue, "Field #{@field.name.inspect}: #{value.inspect} is outside the range of a " \
                                               "Parquet int64")
      end

      def decimal(value)
        unless value.finite?
          raise(IOStreams::Errors::InvalidValue, "Field #{@field.name.inspect}: #{value.inspect} is not finite, so it " \
                                                 "cannot be written as a Parquet decimal")
        end

        rounded = @field.round(value)
        return rounded if rounded.abs < 10**(PRECISION - @field.decimals)

        raise(IOStreams::Errors::InvalidValue, "Field #{@field.name.inspect}: #{value.to_s('F')} has more than " \
                                               "#{PRECISION - @field.decimals} digits before its decimal point, which " \
                                               "a Parquet decimal(#{PRECISION}, #{@field.decimals}) cannot hold")
      end
    end
  end
end
