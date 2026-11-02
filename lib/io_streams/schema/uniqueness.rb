# frozen_string_literal: true

module IOStreams
  class Schema
    # The values seen of each field or key of a schema whose values must be unique within a file, as Frictionless
    # defines them, see https://datapackage.org/standard/table-schema/: a field with the constraint `unique`, the
    # `primaryKey`, and each of the `uniqueKeys`, each checked separately, as Frictionless requires.
    #
    # One read or one write of a file holds its own, see `IOStreams::Schema#uniqueness`, which `IOStreams::Schema::Columns`
    # asks to check the values of each row or record once it has converted them, since the values seen belong to that
    # read or write, rather than to the schema or its fields, which many reads share.
    #
    # A value that is nil is not compared, as SQL compares the values of a unique key, so a key of several fields whose
    # value of any of them is nil is not either. The fields of the `primaryKey` are required, so they always have a
    # value.
    #
    # It remembers up to `limit` distinct values of each field or key, so that it does not fill the memory, and raises
    # `IOStreams::Errors::UniqueLimitExceeded` for a value that it would have to remember beyond them, since it could no
    # longer tell whether a value is a duplicate.
    class Uniqueness
      # The values of one field or key, see `IOStreams::Schema::Uniqueness`.
      class Key
        # Returns [String] what the key is, for the messages of its errors, such as `Field "id"`.
        attr_reader :label

        # Returns [Array<IOStreams::Schema::Field>] the fields of the key, in order.
        attr_reader :fields

        def initialize(label, fields, limit)
          @label  = label
          @fields = fields
          @single = fields.size == 1
          @limit  = limit
          @seen   = {}
        end

        # Returns [Object|nil] the value of the key of the supplied values of the fields, or nil when it is not compared,
        # since the value of one of its fields is nil.
        def value_of(values)
          return values[@fields.first] if @single

          tuple = @fields.map { |field| values[field] }
          tuple unless tuple.include?(nil)
        end

        # Raises `IOStreams::Errors::InvalidValue` when the value was seen before, and
        # `IOStreams::Errors::UniqueLimitExceeded` when it would be one more distinct value than the limit.
        def check(value)
          if @seen.key?(value)
            text = value.inspect
            text = "#{text[0, 60]}..." if text.length > 63
            raise(IOStreams::Errors::InvalidValue.new("#{@label}: #{text} is not unique, it is the value of an earlier " \
                                                      "record", field: field_name, value: value))
          end
          return if @seen.size < @limit

          raise(IOStreams::Errors::UniqueLimitExceeded,
                "#{@label}: the uniqueness of its values cannot be checked beyond #{@limit} distinct values, the " \
                "uniqueLimit of the schema, which IOStreams remembers for each read or write. Raise uniqueLimit, or " \
                "check their uniqueness elsewhere, such as with a unique index of a database")
        end

        # Remembers the value, once every field and key of the record has been checked, see
        # `IOStreams::Schema::Uniqueness#check`.
        def add(value)
          @seen[value] = true
        end

        private

        # Returns [String|Symbol|Array] the name of the field, or the names of the fields of a key of several, for
        # `IOStreams::Errors::InvalidValue#field`.
        def field_name
          @single ? @fields.first.name : @fields.map(&:name)
        end
      end

      # Parameters:
      #   keys: [Array<Array(String, Array<IOStreams::Schema::Field>)>]
      #     What each field or key is, for the messages of its errors, and its fields.
      #
      #   limit: [Integer]
      #     The most distinct values that it remembers of each field or key, see above.
      def initialize(keys, limit)
        @keys   = keys.map { |label, fields| Key.new(label, fields, limit) }
        @fields = @keys.flat_map(&:fields).to_h { |field| [field, true] }.compare_by_identity
      end

      # Checks the values of the fields of one row or record, read or written, supplied as pairs of each field and its
      # value, of which it takes only those of its keys, before it remembers them, so that a record that raises adds
      # none of its values.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value of a field or key is not unique, and
      # `IOStreams::Errors::UniqueLimitExceeded` when it would remember more distinct values than its limit.
      def check(pairs)
        values = {}.compare_by_identity
        pairs.each { |field, value| values[field] = value if @fields.key?(field) }
        keyed = @keys.filter_map do |key|
          value = key.value_of(values)
          [key, value] unless value.nil?
        end
        keyed.each { |key, value| key.check(value) }
        # A loop of its own, so that every key is checked before any is added, and a record that raises adds none.
        keyed.each { |key, value| key.add(value) } # rubocop:disable Style/CombinableLoops
        nil
      end
    end
  end
end
