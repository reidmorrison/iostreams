# frozen_string_literal: true

module IOStreams
  class Schema
    # The values seen of each field or key of a schema whose values must be unique within a file, as Frictionless
    # defines them, see https://datapackage.org/standard/table-schema/: a field with the constraint `unique`, the
    # `primaryKey`, and each of the `uniqueKeys`, each checked separately, as Frictionless requires.
    #
    # One read or one write of a file holds its own, see `IOStreams::Schema#uniqueness`, which `IOStreams::Schema::Columns`
    # asks to check the values of each row or record once it has converted them, since the values seen belong to that
    # read or write, rather than to the schema or its fields, which many reads share. It checks the values of every key
    # of a row or record before it remembers any, and remembers them only once the whole row or record is read or
    # written, see #check and #add, so that a row or record that raises, or that a contract then rejects, adds none.
    #
    # A value that is nil is not compared, as SQL compares the values of a unique key, so a key of several fields whose
    # value of any of them is nil is not either. The fields of the `primaryKey` are required, so they always have a
    # value. It remembers a frozen copy of each value, so that a caller that changes a record, such as with
    # `String#upcase!`, does not change the values seen.
    #
    # It remembers up to `limit` distinct values of each field or key, so that it does not fill the memory, and raises
    # `IOStreams::Errors::UniqueLimitExceeded` for a value that it would have to remember beyond them, since it could no
    # longer tell whether a value is a duplicate.
    class Uniqueness
      # The values of one field or key, see `IOStreams::Schema::Uniqueness`.
      class Key
        # Returns [String] what the key is, for the messages of its errors, such as `Field "id"`.
        attr_reader :label

        # Parameters:
        #   label: [String]
        #     What the key is, see #label.
        #
        #   fields: [Array<IOStreams::Schema::Field>]
        #     The fields of the key, in order.
        #
        #   indexes: [Array<Integer>]
        #     The position of each field of the key within the fields of the uniqueness, see
        #     `IOStreams::Schema::Uniqueness#fields`.
        #
        #   limit: [Integer]
        #     The most distinct values that it remembers.
        def initialize(label, fields, indexes, limit)
          @label   = label
          @fields  = fields
          @indexes = indexes
          @single  = fields.size == 1 ? indexes.first : nil
          @limit   = limit
          @seen    = {}
        end

        # Returns [Object|nil] the value of the key in the row or record, at the supplied position of each field of the
        # uniqueness, see `IOStreams::Schema::Uniqueness#check`, or nil when it is not compared, since the value of one
        # of its fields is nil, without an Array for a key of one field.
        def value_of(values, positions)
          return value_at(values, positions[@single]) if @single

          tuple = @indexes.map { |index| value_at(values, positions[index]) }
          tuple unless tuple.include?(nil)
        end

        # Raises `IOStreams::Errors::InvalidValue` when the value was seen before, and
        # `IOStreams::Errors::UniqueLimitExceeded` when it would be one more distinct value than the limit.
        def check(value)
          if @seen.key?(value)
            raise(IOStreams::Errors::InvalidValue.new("#{@label}: #{text(value)} is not unique, it is the value of an " \
                                                      "earlier record", field: field_name, value: value))
          end
          return if @seen.size < @limit

          raise(IOStreams::Errors::UniqueLimitExceeded,
                "#{@label}: the uniqueness of its values cannot be checked beyond #{@limit} distinct values, the " \
                "uniqueLimit of the schema, which IOStreams remembers for each read or write. Raise uniqueLimit, or " \
                "check their uniqueness elsewhere, such as with a unique index of a database")
        end

        # Remembers a frozen copy of the value, once every field and key of the row or record has been checked, see
        # `IOStreams::Schema::Uniqueness#add`.
        def add(value)
          @seen[Utils.frozen_copy(value)] = true
        end

        private

        # Returns the value at the position, a key of a record or an index of a row, or nil for a field that the row or
        # record does not have, at the position nil.
        def value_at(values, position)
          values[position] unless position.nil?
        end

        # Returns [String] the value as its fields write it, for the message of an error, such as `"1.50"` for a number,
        # or `"US", "1"` for a key of several fields, see `IOStreams::Schema::Field#text_of`.
        def text(value)
          values = @single ? [value] : value
          texts  = @fields.zip(values).map { |field, item| field.text_of(item).inspect }
          Field.message_text(texts.join(", "))
        end

        # Returns [String|Symbol|Array] the name of the field, or the names of the fields of a key of several, for
        # `IOStreams::Errors::InvalidValue#field`.
        def field_name
          @single ? @fields.first.name : @fields.map(&:name)
        end
      end

      # Returns [Array<IOStreams::Schema::Field>] the fields whose values it checks, each once, in the order of the
      # positions that #check takes, so that the reader or writer finds their values once for each list of columns.
      attr_reader :fields

      # Parameters:
      #   keys: [Array<Array(String, Array<IOStreams::Schema::Field>)>]
      #     What each field or key is, for the messages of its errors, and its fields.
      #
      #   limit: [Integer]
      #     The most distinct values that it remembers of each field or key, see above.
      def initialize(keys, limit)
        @fields = keys.flat_map(&:last).uniq(&:object_id).freeze
        # By identity from the start, since two fields of the same name and properties are equal, see
        # `IOStreams::Schema#namesake`, while each has its own values.
        index = {}.compare_by_identity
        @fields.each_with_index { |field, position| index[field] = position }
        @keys = keys.map { |label, fields| Key.new(label, fields, fields.map { |field| index[field] }, limit) }.freeze
      end

      # Returns [Array|nil] the value of each key of the row or record, in the order of its keys, nil for one that is not
      # compared, once each one is checked, which #add then remembers, or nil when it has no value to remember. The
      # values are those of the row or record, an Array or a Hash, at the supplied position of each field of #fields,
      # an index of the row or a key of the record, or nil for a field that it does not have.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value of a field or key is not unique, and
      # `IOStreams::Errors::UniqueLimitExceeded` when it would remember more distinct values than its limit.
      def check(values, positions)
        pending = nil
        @keys.each_with_index do |key, index|
          value = key.value_of(values, positions)
          next if value.nil?

          key.check(value)
          (pending ||= Array.new(@keys.size))[index] = value
        end
        pending
      end

      # Remembers the values of the keys of a row or record that #check returned, once the whole row or record has been
      # read or written.
      def add(pending)
        return if pending.nil?

        @keys.each_with_index { |key, index| key.add(pending[index]) unless pending[index].nil? }
        nil
      end
    end
  end
end
