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
      # The types of field whose values cannot be empty, so that a column that is never null always has a value, which a
      # field that is required checks, see #field. A string, or a value of any type, such as of a binary or JSON column,
      # can be empty, which a field that is required rejects.
      REQUIRABLE_TYPES = %w[integer number boolean date datetime].freeze

      # The most digits that a 64-bit integer holds, whatever they are, see #integer_properties.
      INTEGER_DIGITS = 18

      # Returns [Array<String>] the names of the columns, in the order of the result.
      attr_reader :names

      # Parameters:
      #   names: [Array<String>]
      #     The name of each column, as the result names it.
      #
      #   types: [Array<ActiveModel::Type::Value>]
      #     The Active Record type of each column, which casts its raw values, as `pluck` chooses it, see
      #     `IOStreams::Query::CastTypes`.
      #
      #   not_null: [Array<true|false>]
      #     Whether each column is never null, such as a column of the table of the model with `NOT NULL`.
      #
      # Raises ArgumentError when two columns have the same name, since a record has one value for each name.
      def initialize(names:, types:, not_null:)
        duplicates = names.tally.select { |_name, count| count > 1 }.keys
        unless duplicates.empty?
          raise(ArgumentError, "The query has more than one column named #{duplicates.map(&:inspect).join(', ')}: give " \
                               "each column a name of its own, such as with `AS`")
        end

        @names    = names.map(&:-@).freeze
        @types    = types.dup.freeze
        @not_null = not_null.dup.freeze
        freeze
      end

      # Returns [Array] the raw values of a row, as the driver of the database returns them, in the order of the
      # columns, each cast by the type of its column, as `pluck` casts them: an enum attribute returns the name of its
      # value, an encrypted attribute its plain text, and a datetime an `ActiveSupport::TimeWithZone` in a Rails app.
      def cast(values)
        types = @types
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
        fields = @names.each_with_index.map { |name, index| field(name, @types[index], @not_null[index]) }
        Utils.frozen_copy({fields: fields})
      end

      private

      # Returns [Hash] the descriptor of the field of a column, see `IOStreams::Schema::Field`: its name, and the type
      # of the values that its Active Record type casts, see #type_properties. A column that is never null is required,
      # when its values cannot be empty, see REQUIRABLE_TYPES.
      def field(name, type, not_null)
        descriptor = {name: name, **type_properties(type)}
        descriptor[:constraints] = {required: true} if not_null && REQUIRABLE_TYPES.include?(descriptor[:type])
        descriptor
      end

      # Returns [Hash] the type of the field whose values the Active Record type casts, and its other properties, such
      # as the decimals of a number, or "any" for a type that a field has no type for, such as JSON, a time of day, or a
      # binary or serialized column, or whose class is not one of Active Model or Active Record, see #own?. The type
      # within the decorators of the type decides it, see #undecorated.
      def type_properties(type)
        type = undecorated(type)
        # Before the type itself, since an enum answers the type of its column, such as :integer, while it casts the
        # names of its values, and a serialized column answers :text, while it casts any object.
        return {type: "string"} if enum?(type)
        return {type: "any"} if serialized?(type) || !own?(type)
        # Such as a decimal without a scale, which casts an Integer.
        return integer_properties(type) if type.is_a?(::ActiveModel::Type::Integer)

        case type.type
        when :integer, :big_integer then {type: "integer"}
        when :decimal, :money then number_properties(type)
        when :float then {type: "number", floatNumber: true}
        when :string, :text, :uuid, :citext, :enum, :inet, :cidr, :macaddr then {type: "string"}
        when :boolean then {type: "boolean"}
        when :date then {type: "date"}
        when :datetime, :timestamp, :timestamptz then {type: "datetime"}
        else {type: "any"}
        end
      end

      # Returns [Hash] an integer, or a number without decimals for an integer of a column that holds more digits than a
      # 64-bit integer does, see INTEGER_DIGITS, such as a `decimal(20, 0)`, whose values a format of 64-bit integers,
      # such as Parquet, could not hold, while a number holds them in any format, as a BigDecimal.
      def integer_properties(type)
        type.precision && type.precision > INTEGER_DIGITS ? {type: "number", decimals: 0} : {type: "integer"}
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

      def enum?(type)
        defined?(::ActiveRecord::Enum::EnumType) && type.is_a?(::ActiveRecord::Enum::EnumType)
      end

      def serialized?(type)
        defined?(::ActiveRecord::Type::Serialized) && type.is_a?(::ActiveRecord::Type::Serialized)
      end
    end
  end
end
