# frozen_string_literal: true

module IOStreams
  class Slice
    # The types of the values of a slice that neither JSON nor BSON holds as they are, so that `IOStreams.slice` turns
    # them back into those types once the slice is stored, see `IOStreams::Slice#to_h`: a Time, a Date, a BigDecimal,
    # an `ActiveSupport::Duration` and an Integer outside of the integers that BSON holds, see
    # `IOStreams::Schema::Field.kept_type`, of a value that no field of a schema describes, such as a value of a row
    # written without a schema to a store of slices in the `:array` or `:hash` format.
    #
    # It holds them by column, the position of a value of a row that is an Array, or the key of a value of a row that is
    # a Hash, see #dump, as `[column, type]` when every value of the column that is not nil is of that type, otherwise
    # as `[column, type, indexes]`, the index of each row whose value of the column is of that type, see #to_a, so that
    # the common case, a column of one type, costs a few bytes for the whole slice.
    class KeptTypes
      # Returns [Hash{Integer => Array}] the index of each row that holds a value to turn back into its type, with the
      # position or key of each such value within the row and the field of its type, `[key, field]`, from the types that
      # #to_a returned, such as once a slice was stored, see `IOStreams::Slice.from_h`. A row whose value of a column is
      # nil, or that does not have the column, such as a blank row, or a record without its key, holds none of it. The
      # key of a value of a Hash is its text, also when the Hash holds it as a Symbol, as a schema with `keyType`
      # "symbol" writes it, until JSON turns it into its text.
      #
      # Raises ArgumentError when the types are not those of the supplied rows: not an Array of `[column, type]` and
      # `[column, type, indexes]`, whose column is an Integer of 0 or more, or a String, whose type is one of
      # `IOStreams::Schema::Field::KEPT_TYPES`, and whose indexes are those of rows, in order.
      def self.plan(types, rows)
        unless types.is_a?(::Array)
          raise(ArgumentError, "The types of the values of a slice must be an Array, not #{types.class.name}")
        end

        fields = {}
        plan   = {}
        types.each do |kept|
          column, type, indexes = checked(kept, rows.size)
          field = fields[type] ||= IOStreams::Schema::Field.new({"name" => type, "type" => type})
          (indexes || rows.each_index).each do |index|
            key = key_of(rows[index], column)
            (plan[index] ||= []) << [key, field] unless key.nil?
          end
        end
        plan
      end

      # Returns [Integer|String|Symbol] the position or key of the value of the column within the supplied row, see #dump,
      # or nil when the row holds no value of it that is not nil.
      def self.key_of(row, column)
        case row
        when ::Array
          column if column.is_a?(::Integer) && !row[column].nil?
        when ::Hash
          return unless column.is_a?(::String)
          return column unless row[column].nil?

          symbol = column.to_sym
          symbol unless row[symbol].nil?
        end
      end

      # Returns [Array(Integer|String, String, Array<Integer>|nil)] the supplied entry of the types of a slice, see .plan.
      def self.checked(kept, size)
        column, type, indexes = kept if kept.is_a?(::Array) && kept.size.between?(2, 3)
        unless ((column.is_a?(::Integer) && !column.negative?) || column.is_a?(::String)) &&
               IOStreams::Schema::Field::KEPT_TYPES.include?(type) && indexes?(indexes, size, kept.size)
          raise(ArgumentError, "Each type of the values of a slice must be [column, type] or [column, type, indexes], " \
                               "whose column is the position or the key of a value, whose type is one of " \
                               "#{IOStreams::Schema::Field::KEPT_TYPES.join(', ')}, and whose indexes are those of its " \
                               "rows, in order: #{kept.inspect}")
        end

        [column, type, indexes]
      end

      # Returns [true|false] whether the supplied indexes are those of rows of a slice of the supplied size, in order, or
      # nil for an entry of two values.
      def self.indexes?(indexes, size, values)
        return indexes.nil? if values == 2
        return false unless indexes.is_a?(::Array) && !indexes.empty?

        indexes.each_cons(2).all? { |before, after| before < after } &&
          indexes.all? { |index| index.is_a?(::Integer) && index >= 0 && index < size }
      end
      private_class_method :key_of, :checked, :indexes?

      def initialize
        # The rows of each column of each type: {column => {type => [index, ...]}}.
        @columns = {}
        # The columns that hold a value that is not nil of no type that is kept, see #dump.
        @others  = nil
        @fields  = {}
      end

      # Returns the supplied value of the column of the row of the supplied index, in a form that JSON and BSON hold:
      # the text that the field of its type writes for it, see `IOStreams::Schema::Field#dump`, for a value of a type
      # that is kept, see `IOStreams::Schema::Field.kept_type`, which it notes, otherwise what the block returns for it,
      # such as its text, as JSON holds it.
      #
      # Parameters
      #   column: [Integer|String]
      #     The position of the value within a row that is an Array, or its key, as its text, within a row that is a
      #     Hash.
      def dump(value, column, index)
        type = IOStreams::Schema::Field.kept_type(value)
        unless type
          (@others ||= {})[column] = true unless value.nil?
          return yield(value)
        end

        ((@columns[column] ||= {})[type] ||= []) << index
        (@fields[type] ||= IOStreams::Schema::Field.new({"name" => type, "type" => type})).dump(value)
      end

      # Returns [Array<Array>] the type of the values of each column that #dump noted, see the class, in the order in
      # which each column was first noted, or nil when it noted none.
      def to_a
        return if @columns.empty?

        @columns.flat_map do |column, types|
          if types.size == 1 && !@others&.key?(column)
            [[column, types.each_key.first]]
          else
            types.map { |type, indexes| [column, type, indexes] }
          end
        end
      end

      def inspect
        "#<#{self.class.name} columns=#{@columns.size}>"
      end
    end
  end
end
