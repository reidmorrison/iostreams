# frozen_string_literal: true

module IOStreams
  class Query
    # The columns of the result of a query: the name of each one, its Active Record type, and whether it is never null,
    # in the order of the result.
    #
    # Casts the raw values of each row the way `pluck` casts them, see #cast, and describes the columns as the fields of a
    # schema, see #schema, which the stream of the query reads its rows by, and gives a copy, see
    # `IOStreams::Query::Stream`. It never knows a format of file: `IOStreams::Parquet::Column`, for example, still turns
    # the fields into Parquet types.
    class Columns
      # The types of field whose values can be empty text: a string, or a value of any type, such as of a binary or JSON
      # column, which a field that is required rejects, see `IOStreams::Schema::Constraints#no_text`, so that a column
      # of them is never required, see #field.
      EMPTY_TEXT_TYPES = %w[string any].freeze

      # The most digits that a 64-bit integer holds, whatever they are, see #integer_properties.
      INTEGER_DIGITS = 18

      # The type of field of each type that an Active Record type names, apart from a number, see #type_properties.
      FIELD_TYPES = {
        integer: "integer", big_integer: "integer",
        string: "string", text: "string", uuid: "string", citext: "string", enum: "string", inet: "string",
        cidr: "string", macaddr: "string",
        boolean: "boolean",
        date: "date",
        datetime: "datetime", timestamp: "datetime", timestamptz: "datetime",
        time: "time",
        interval: "duration"
      }.freeze

      # The type that casts the value of a column as the text that the database returns, see #initialize.
      TEXT = ActiveModel::Type::String.new

      # The raw text of a time of day, as the databases return it: optionally a date, such as Active Record writes on
      # SQLite, then the hour, which MySQL allows to be negative, or of more than two digits, see #check_clock.
      CLOCK = /\A(-)?(?:\d{4}-\d{2}-\d{2}[ T])?(\d+):\d{2}/

      # The raw text of an infinite interval, which PostgreSQL 17 holds, in every `IntervalStyle`, see #check_duration.
      INFINITE = /\A-?infinity\z/

      # Returns [Array<String>] the names of the columns, in the order of the result.
      attr_reader :names

      # Parameters:
      #   names: [Array<String>]
      #     The name of each column, as the result names it.
      #
      #   types: [Array<ActiveModel::Type::Value>]
      #     The Active Record type of each column, which casts its raw values, as `pluck` chooses it, see
      #     `IOStreams::Query::CastTypes`. A PostgreSQL `inet` or `cidr` address is cast as the text that PostgreSQL
      #     returns instead, such as "10.0.0.0/8", also within decorators, and an array of them as an array of that text,
      #     since its type casts an IPAddr, whose text drops the prefix, and which drops the host of an address with one,
      #     see #cast_type.
      #
      #   not_null: [Array<true|false>]
      #     Whether each column is never null, such as a column of the table of the model with `NOT NULL`.
      #
      #   requirable_types: [Array<String>]
      #     The types of field whose columns that are never null always have a value once Active Record casts it, on the
      #     database of the query, which the source of the database knows, such as
      #     `IOStreams::Query::SqliteStatement.requirable_types`, so that a field of them is required when its column is
      #     never null, see #field, apart from those whose values can be empty text, see EMPTY_TEXT_TYPES.
      #
      #   unknown: [Array<true|false>]
      #     Whether the database gives each column a type that Active Record does not know, such as a PostgreSQL
      #     `timetz`, which Active Record casts with `ActiveModel::Type::Value`, returning the value as the driver returns
      #     it, so that a column that Active Record casts so too is of the `unknown_type`, see #field. A column that the
      #     database gives a type that Active Record knows, such as a column of a common table expression, keeps the
      #     value that the driver casts, even when Active Record casts it with `ActiveModel::Type::Value`.
      #     Default: none
      #
      #   unknown_type: [String]
      #     The type of field of a column of a type that Active Record does not know, see `unknown`, on the database of
      #     the query, which the source of the database knows, such as "string" for PostgreSQL, which returns the text of
      #     such a value, see `IOStreams::Query::PostgresqlCursor.unknown_type`.
      #     Default: "any"
      #
      # Raises ArgumentError when two columns have the same name, since a record has one value for each name.
      def initialize(names:, types:, not_null:, requirable_types:, unknown: [], unknown_type: "any")
        duplicates = names.tally.select { |_name, count| count > 1 }.keys
        unless duplicates.empty?
          raise(ArgumentError, "The query has more than one column named #{duplicates.map(&:inspect).join(', ')}: give " \
                               "each column a name of its own, such as with `AS`")
        end

        @names            = names.map(&:-@).freeze
        @types            = types.map { |type| cast_type(type) }.freeze
        @not_null         = not_null.dup.freeze
        @requirable_types = (requirable_types - EMPTY_TEXT_TYPES).freeze
        @unknown          = unknown.dup.freeze
        @unknown_type     = -unknown_type
        @clocks           = indexes_of("time")
        @durations        = indexes_of("duration")
        @checks           = !(@clocks.empty? && @durations.empty?)
        @text_values      = !@clocks.empty? && @types.all? { |type| casts_text?(type) }
        freeze
      end

      # Returns [true|false] whether the raw values of a row are to be the text that the database returns, rather than
      # values that the driver casts, so that #cast can check them: those of a query with a time of day, which a driver
      # such as mysql2 casts to nil, or to a time of the next day, when it is outside a day, see #check_clock, when the
      # type of each column casts its text as it casts the value of the driver, see #casts_text?. A query that also has a
      # column whose values only the driver casts, such as one that it computes, keeps the values of the driver, so that
      # its values are those of `pluck`, as is every query read in Rails' batches.
      def text_values?
        @text_values
      end

      # Returns [Array] the raw values of a row, as the driver of the database returns them, in the order of the
      # columns, each cast by the type of its column, as `pluck` casts them: an enum attribute returns the name of its
      # value, an encrypted attribute its plain text, and a datetime an `ActiveSupport::TimeWithZone` in a Rails app.
      #
      # Raises `IOStreams::Errors::InvalidValue` for a value that Active Record would cast to a wrong one: a time of day
      # outside a day, see #check_clock, or an infinite interval, see #check_duration.
      def cast(values)
        types = @types
        check_values(values) if @checks
        Array.new(values.size) { |index| types[index].deserialize(values[index]) }
      end

      # Raises `IOStreams::Errors::InvalidHeader` unless the supplied names, of the columns of a result of the query, are
      # the names of these columns, which the query was described by, since the values of each row are cast by their
      # position, for example when the table changed between the two.
      def check(names)
        return if names == @names

        raise(IOStreams::Errors::InvalidHeader, "The columns of the query changed after it was described, from " \
                                                "#{@names.inspect} to #{names.inspect}")
      end

      # Returns [Hash] the descriptor of the schema whose fields are these columns, in order, see `IOStreams::Schema`,
      # each of the type of the values that its Active Record type casts, see #field. It is frozen.
      def schema
        fields = @names.each_with_index.map { |name, index| field(name, @types[index], @not_null[index], @unknown[index]) }
        Utils.frozen_copy({fields: fields})
      end

      private

      # Returns [Array<Integer>] the indexes of the columns whose field is of the supplied type, see #type_properties.
      def indexes_of(field_type)
        @types.each_index.select { |index| type_properties(@types[index])[:type] == field_type }.freeze
      end

      # Raises `IOStreams::Errors::InvalidValue` for a raw value of a row that Active Record would cast to a wrong one,
      # see #cast.
      def check_values(values)
        @clocks.each { |index| check_clock(values[index], index) }
        @durations.each { |index| check_duration(values[index], index) }
      end

      # Raises `IOStreams::Errors::InvalidValue` for the raw value of an infinite interval, `infinity` or `-infinity`,
      # which PostgreSQL 17 holds, rather than export the nil that Active Record casts it to, which a duration cannot
      # hold either.
      def check_duration(value, index)
        return unless value.is_a?(String) && INFINITE.match?(value)

        raise(IOStreams::Errors::InvalidValue, "Column #{@names[index].inspect}: #{value.inspect} is an infinite interval, " \
                                               "which a duration field cannot hold, and Active Record reads as nil, so " \
                                               "select it as null when it is not finite, or as text, instead")
      end

      # Raises `IOStreams::Errors::InvalidValue` for the raw value of a time of day that is outside a day, from 00:00:00
      # to 23:59:59, such as PostgreSQL's `24:00:00`, or a MySQL `TIME`, which holds a length of time too, such as
      # `25:30:00` or `-01:00:00`, rather than export a value that Active Record casts to nil, or to a time of the next
      # day, whose time of day is then wrong. Its text is checked, as the databases return it, or the time that a driver
      # casts it to, which is on 2000-01-01 when it is within a day, such as when mysql2 reads it in Rails' batches.
      # Other text is left to Active Record, as `pluck` leaves it.
      def check_clock(value, index)
        case value
        when String
          clock = CLOCK.match(value)
          return if clock.nil? || (clock[1].nil? && clock[2].to_i < 24)
        when Time
          return if value.day == 1 && value.month == 1 && value.year == 2000
        else
          return
        end

        raise(IOStreams::Errors::InvalidValue, "Column #{@names[index].inspect}: #{value.inspect} is not a time of day, " \
                                               "from 00:00:00 to 23:59:59, which a time field holds, so select it as " \
                                               "text, or as a number of seconds, instead")
      end

      # Returns [Hash] the descriptor of the field of a column, see `IOStreams::Schema::Field`: its name, and the type
      # of the values that its Active Record type casts, see #type_properties, or the `unknown_type` for a column of a
      # type that neither the database nor Active Record knows, see #initialize. A column that is never null is required,
      # when a column of its type always has a value once cast on the database, see `requirable_types` in #initialize.
      def field(name, type, not_null, unknown)
        unknown  &&= undecorated(type).instance_of?(::ActiveModel::Type::Value)
        descriptor = {name: name, **(unknown ? {type: @unknown_type} : type_properties(type))}
        descriptor[:constraints] = {required: true} if not_null && @requirable_types.include?(descriptor[:type])
        descriptor
      end

      # Returns [Hash] the type of the field whose values the Active Record type casts, and its other properties, such
      # as the decimals of a number, or "any" for a type that a field has no type for, such as JSON, or a binary or
      # serialized column, or whose class is not one of Active Model or Active Record, see #own?. A time of day is a
      # time, and a PostgreSQL interval, which Active Record casts to an `ActiveSupport::Duration`, a duration. The type
      # within the decorators of the type decides it, see #undecorated.
      def type_properties(type)
        type = undecorated(type)
        # Before the type itself, since an enum answers the type of its column, such as :integer, while it casts the
        # names of its values, and a serialized column answers :text, while it casts any object.
        return {type: "string"} if enum?(type)
        return {type: "any"} if serialized?(type) || !own?(type)
        # Before the type itself, since an array answers the type of its elements.
        return {type: "array"} if postgresql_array?(type)
        # Such as a decimal without a scale, which casts an Integer.
        return integer_properties(type) if type.is_a?(::ActiveModel::Type::Integer)

        case type.type
        when :decimal, :money then number_properties(type)
        when :float then {type: "number", floatNumber: true}
        else {type: FIELD_TYPES.fetch(type.type, "any")}
        end
      end

      # Returns [Hash] an integer, or a number without decimals for an integer of a column whose values can be beyond
      # those of a 64-bit integer, which a format of 64-bit integers, such as Parquet, could not hold, while a number
      # holds them in any format, as a BigDecimal: one that holds more digits than a 64-bit integer does, see
      # INTEGER_DIGITS, such as a `decimal(20, 0)`, or an unsigned integer of 8 bytes, such as a MySQL `bigint unsigned`,
      # whose values reach 18446744073709551615.
      def integer_properties(type)
        wide = (type.precision && type.precision > INTEGER_DIGITS) || unsigned_64_bit?(type)
        wide ? {type: "number", decimals: 0} : {type: "integer"}
      end

      # Returns [true|false] whether the type is an unsigned integer of 8 bytes, whose values a 64-bit integer, which is
      # signed, holds only up to half of, see #integer_properties.
      def unsigned_64_bit?(type)
        defined?(::ActiveRecord::Type::UnsignedInteger) && type.is_a?(::ActiveRecord::Type::UnsignedInteger) &&
          type.limit.to_i >= 8
      end

      # Returns [ActiveModel::Type::Value] the type that casts the raw values of a column of the supplied type: the type
      # itself, apart from a PostgreSQL address, `inet` or `cidr`, within the decorators of the type, if any, see
      # #undecorated, which is cast as the text that PostgreSQL returns instead, see TEXT, such as "192.168.1.5/24", and
      # an array of addresses, which is cast as an array of that text. The type of an address casts an IPAddr, whose text
      # drops the prefix, and the host of an address with both, such as 192.168.1.0 for 192.168.1.5/24. The decorators
      # of an address, such as that of `normalizes`, only change the values that are written, not those that are read.
      def cast_type(type)
        inner = undecorated(type)
        return TEXT if postgresql_address?(inner)
        return text_array(inner) if postgresql_array?(inner) && postgresql_address?(inner.subtype)

        type
      end

      # Returns [ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array] a PostgreSQL array with the delimiter of the
      # supplied one, whose elements are cast as the text that PostgreSQL returns, see TEXT and #cast_type.
      def text_array(array)
        ::ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(TEXT, array.delimiter)
      end

      # Returns [true|false] whether the type is a PostgreSQL address, `inet` or `cidr`, which casts an IPAddr.
      def postgresql_address?(type)
        defined?(::ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Cidr) &&
          type.is_a?(::ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Cidr)
      end

      # Returns [true|false] whether the type is a PostgreSQL array, which casts an Array.
      def postgresql_array?(type)
        defined?(::ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array) &&
          type.is_a?(::ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array)
      end

      # Returns [Hash] a number with the decimals of the scale of its column, or without decimals when it has no scale,
      # such as a PostgreSQL `numeric`, or a sum.
      def number_properties(type)
        type.scale ? {type: "number", decimals: type.scale} : {type: "number"}
      end

      # Returns [ActiveModel::Type::Value] the type within the decorators of Active Model and Active Record that wrap it,
      # which cast the values that it casts, and answer its `type`, such as of an encrypted attribute, which decrypts
      # the value first, of a normalized one, or of a time in the time zone of the application, so that the type within
      # them decides the field, see #type_properties. Each decorator knows the type within it: an encrypted attribute
      # its `cast_type`, and a `Delegator`, such as `TimeZoneConverter` or `NormalizedValueType`, its `__getobj__`. A
      # serialized attribute is a `Delegator` too, whose coder casts any object, so it is not looked through, nor is an
      # enum, which casts the names of its values, a type that holds others, such as an array of a PostgreSQL column,
      # or a type of the application, see #own?.
      def undecorated(type)
        while (inner = decorated(type))
          type = inner
        end
        type
      end

      # Returns [ActiveModel::Type::Value|nil] the type that the type decorates, see #undecorated, or nil when it is not a
      # decorator of Active Model or Active Record.
      def decorated(type)
        return unless own?(type) && !serialized?(type)
        return type.__getobj__ if type.is_a?(::Delegator)

        type.cast_type if type.respond_to?(:cast_type)
      end

      # Returns [true|false] whether the class of the type is one of Active Model or Active Record, or of an adapter of a
      # database in their namespace, so that its values are of the type that it answers, see #type_properties, unlike a
      # type of the application or of another gem, such as a subclass of `ActiveModel::Type::Integer` whose
      # `deserialize` returns an object of the application.
      def own?(type)
        name = type.class.name
        !name.nil? && name.start_with?("ActiveModel::", "ActiveRecord::")
      end

      # Returns [true|false] whether the type casts the text of a value, as the database returns it, as it casts the value
      # that the driver casts from that text: a type of Active Model or Active Record that knows the type of its values,
      # within its decorators, see #undecorated, unlike `ActiveModel::Type::Value`, which returns either as it is, such
      # as for a column that the query computes, or a type of the application, see #own?, see #text_values?.
      def casts_text?(type)
        type = undecorated(type)
        own?(type) && !type.instance_of?(::ActiveModel::Type::Value)
      end

      def enum?(type)
        defined?(::ActiveRecord::Enum::EnumType) && type.is_a?(::ActiveRecord::Enum::EnumType)
      end

      def serialized?(type)
        defined?(::ActiveRecord::Type::Serialized) && type.is_a?(::ActiveRecord::Type::Serialized)
      end
    end
  end
end
