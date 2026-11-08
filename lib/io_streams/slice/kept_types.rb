# frozen_string_literal: true

module IOStreams
  class Slice
    # The types of the values of a slice that neither JSON nor BSON holds as they are, so that `IOStreams.slice` turns
    # them back into those types once the slice is stored, see `IOStreams::Slice#to_h`: a Time, a Date, a BigDecimal,
    # an `ActiveSupport::Duration`, an Integer outside of the integers that BSON holds, and a Hash or an Array that holds
    # one, see `IOStreams::Schema::Field.kept_type`, of a value that no field of a schema describes, such as a value of a
    # row written without a schema to a store of slices in the `:array` or `:hash` format, or a value of a field of type
    # "any", whose type does not say what it holds, or of a column that the schema of the slice does not list, see
    # `IOStreams::Slice#dumped_rows`.
    #
    # It holds them by column, the position of a value of a row that is an Array, or the key of a value of a row that is
    # a Hash, see #dump, as `[column, type]` when every value of the column that is not nil is of that type, otherwise
    # as `[column, type, indexes]`, the index of each row whose value of the column is of that type, see #to_a, so that
    # the common case, a column of one type, costs a few bytes for the whole slice.
    class KeptTypes
      # Returns [Hash{Integer => Array}] the index of each row that holds a value to turn back into its type, with the
      # position or key of each such value within the row and the field of its type, `[key, field]`, from the types that
      # #to_a returned, such as once a slice was stored, see `IOStreams::Slice.from_h`. The field is named by the column,
      # its label in the supplied header row, or its key, so that an `IOStreams::Errors::InvalidValue` names it. A row
      # whose value of a column is nil, or that does not have the column, such as a blank row, or a record without its
      # key, holds none of it. The key of a value of a Hash is its text, also when the Hash holds it as a Symbol, as a
      # schema with `keyType` "symbol" writes it, until JSON turns it into its text.
      #
      # Raises ArgumentError when the types are not those of the supplied rows: not an Array of `[column, type]` and
      # `[column, type, indexes]`, whose column is an Integer of 0 or more, or a String, whose type is one of
      # `IOStreams::Schema::Field::KEPT_TYPES`, and whose indexes are those of rows, in order, each of which holds a value
      # of the column, or a `[column, type]` of a column that no row holds a value of, or two types of the value of a
      # column of a row.
      def self.plan(types, rows, header)
        unless types.is_a?(::Array)
          raise(ArgumentError, "The types of the values of a slice must be an Array, not #{types.class.name}")
        end

        plan = {}
        # The columns that a `[column, type]` names in every row, and the rows of the columns that `[column, type,
        # indexes]` names, so that no value is named twice, checked once for each type, rather than for each value.
        whole = {}
        parts = {}
        types.each do |kept|
          column, type, indexes = checked(kept, rows.size)
          field = field_of(column, type, header)
          if indexes
            not_held(kept, "another type names every value of its column") if whole.key?(column)
            plan_rows(plan, kept, rows, parts[column] ||= {}, field)
          else
            not_held(kept, "another type names a value of its column") if whole.key?(column) || parts.key?(column)
            whole[column] = true
            plan_column(plan, kept, rows, field)
          end
        end
        plan
      end

      # Adds the value of the column of each row of the indexes of the type to the plan, see .plan, each of which must
      # hold one that no other type named, see the supplied rows seen.
      def self.plan_rows(plan, kept, rows, seen, field)
        column, _type, indexes = kept
        indexes.each do |index|
          key = key_of(rows[index], column)
          not_held(kept, "row #{index} holds no value of its column, or another type names it") if key.nil? || seen[index]
          seen[index] = true
          (plan[index] ||= []) << [key, field]
        end
      end

      # Adds the value of the column of every row that holds one to the plan, see .plan, which some row must hold.
      def self.plan_column(plan, kept, rows, field)
        column = kept.first
        found  = false
        rows.each_index do |index|
          key = key_of(rows[index], column)
          next if key.nil?

          found = true
          (plan[index] ||= []) << [key, field]
        end
        not_held(kept, "no row holds its column") unless found
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

      # Returns [IOStreams::Schema::Field] the field of the type that turns back the values of the column, named by its
      # label in the header row, or its position when it has none, or its key, see .plan.
      def self.field_of(column, type, header)
        name = column.is_a?(::Integer) ? header&.[](column).to_s : column
        name = column.to_s if name.empty?
        IOStreams::Schema::Field.new({"name" => name, "type" => type})
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
        return false unless indexes.all? { |index| index.is_a?(::Integer) && index >= 0 && index < size }

        indexes.each_cons(2).all? { |before, after| before < after }
      end

      # Raises ArgumentError for the supplied type of the values of a slice, which is not that of its rows for the supplied
      # reason.
      def self.not_held(kept, reason)
        raise(ArgumentError, "The type #{kept.inspect} of the values of a slice is not that of its rows: #{reason}")
      end
      private_class_method :plan_rows, :plan_column, :field_of, :checked, :indexes?, :not_held

      def initialize
        # The rows of each column of each type: {column => {type => [index, ...]}}.
        @columns = {}
        # The index of the last row of each column noted, see #dump.
        @last    = {}
        @fields  = {}
      end

      # Returns the supplied value of the column of the row of the supplied index, in a form that JSON and BSON hold:
      # the text that the field of its type writes for it, see `IOStreams::Schema::Field#dump`, for a value of a type
      # that is kept, see `IOStreams::Schema::Field.kept_type`, which it notes, the JSON text of a Hash or an Array that
      # holds an Integer that BSON does not hold, which it notes as an "object" or "array", see
      # `IOStreams::Schema::Field.structure_data`, which decides it once, in the walk that gives any other Hash or
      # Array as JSON holds it, and any other value as JSON holds it, as a field of type "any" holds it, see
      # `IOStreams::Schema::Field.any_data`, such as a Symbol as its text.
      #
      # Parameters
      #   column: [Integer|String]
      #     The position of the value within a row that is an Array, or its key, as its text, within a row that is a
      #     Hash.
      #
      # A row that holds a column twice, such as a record of a schema with both the key "due" and the key `:due`, which
      # JSON holds as one key, has the type of the first value that it notes, and its other values of the column are
      # held in the same form, but not noted, so that a row is never noted twice, which `.plan` raises for, and so that
      # each of them is one that JSON and BSON hold, such as an Integer that BSON does not hold as its digits.
      def dump(value, column, index)
        return structure(value, column, index) if value.is_a?(::Hash) || value.is_a?(::Array)

        type = IOStreams::Schema::Field.kept_type(value)
        return IOStreams::Schema::Field.any_data(value) if type.nil?

        note(column, type, index)
        (@fields[type] ||= IOStreams::Schema::Field.new({"name" => type, "type" => type})).dump(value)
      end

      # Returns [Array<Array>] the type of the values of each column that #dump noted, see the class, in the order in
      # which each column was first noted, `[column, type]` when every row of the supplied rows, as they are stored,
      # that holds a value of the column that is not nil holds one of the type, or nil when it noted none.
      def to_a(rows)
        return if @columns.empty?

        @columns.flat_map do |column, types|
          if types.size == 1 && every_row?(rows, column, types.each_value.first.size)
            [[column, types.each_key.first]]
          else
            types.map { |type, indexes| [column, type, indexes] }
          end
        end
      end

      def inspect
        "#<#{self.class.name} columns=#{@columns.size}>"
      end

      private

      # Returns the supplied Hash or Array of the column of the row of the supplied index, see #dump: its JSON text,
      # noted as an "object" or "array", when `IOStreams::Schema::Field.structure_data` gives one, otherwise as JSON
      # holds it.
      def structure(value, column, index)
        data, text = IOStreams::Schema::Field.structure_data(value)
        return data if text.nil?

        note(column, value.is_a?(::Hash) ? "object" : "array", index)
        text
      end

      # Notes that the value of the column of the row of the supplied index is of the supplied type, see #to_a, unless
      # it already noted one of the column of that row, see #dump.
      def note(column, type, index)
        return if @last[column] == index

        @last[column] = index
        ((@columns[column] ||= {})[type] ||= []) << index
      end

      # Returns [true|false] whether the supplied number of rows that hold a value of a type of the column is every row
      # that holds a value of it that is not nil, see #to_a, also by a Symbol key, as the record of a schema with
      # `keyType` "symbol" holds it, see `IOStreams::Slice#dumped_rows`.
      def every_row?(rows, column, count)
        holding = 0
        rows.each { |row| holding += 1 unless self.class.key_of(row, column).nil? }
        holding == count
      end
    end
  end
end
