# frozen_string_literal: true

module IOStreams
  class Schema
    # The columns of one file, matched to the fields of its schema: the columns of its header row, or the keys of each
    # record of a format whose records supply their own keys, such as JSON. The schema finds the field of each column,
    # see `IOStreams::Schema#field_for`, and checks them against its `fieldsMatch`, see
    # `IOStreams::Schema#check_columns`.
    #
    # Converts each row and record that is read into the values of its fields, in the order of the fields, and gives the
    # value of each field of each row and record that is written, so that the columns that the schema does not list are
    # skipped. A column is matched once, when the header row is read, or once for the keys of the records, which are
    # usually the same for every record, rather than for each value.
    #
    # Each reader or writer has its own, see `IOStreams::Schema#columns`, since it holds the columns of its file.
    class Columns
      # A value that no record holds, for a key that a record does not have, see #render_record.
      MISSING = Object.new.freeze

      def initialize(schema)
        @schema     = schema
        # Each field of the header row, in the order of the fields, with the position of its column.
        @matched    = nil
        # The keys of the last record read or written, and each field that they supply, with its key.
        @read_keys  = nil
        @read_plan  = nil
        @write_keys   = nil
        @write_fields = false
        @write_plan   = nil
      end

      # Matches the columns of a header row to the fields.
      #
      # Returns [Array<String|Symbol>] the names of the fields of the columns, in the order of the fields.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when the columns do not match the fields, see
      # `IOStreams::Schema#check_columns`.
      def match(labels)
        found, unknown, positions = find_fields(labels, "column")
        @schema.check_columns(found, unknown, ordered: true, noun: "column")
        @matched = @schema.fields.filter_map { |field| [field, positions[field]] if positions.key?(field) }
        names
      end

      # Matches the columns of a file without a header row, which are the fields, in order.
      def match_fields
        @matched = @schema.fields.each_with_index.to_a
      end

      # Returns [true|false] whether the columns of the file are known, see #match.
      def matched?
        !@matched.nil?
      end

      # Returns [Array<String|Symbol>] the names of the fields of the columns, in the order of the fields.
      def names
        matched.map { |field, _index| field.name }
      end

      # Returns [Array] the values of a row read, in the order of the columns, converted to the type of each field,
      # in the order of the fields, without the columns that the schema does not list.
      def row(values)
        matched.map { |field, index| field.cast(values[index]) }
      end

      # Returns [Hash] the values of a row read, in the order of the columns, converted to the type of each field, by
      # the name of the field, in the order of the fields.
      def record(values)
        record = {}
        matched.each { |field, index| record[field.name] = field.cast(values[index]) }
        record
      end

      # Returns [Hash] a record read, whose keys are its columns, converted to the type of each field, by the name of
      # the field, in the order of the fields.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when its keys do not match the fields, see
      # `IOStreams::Schema#check_columns`.
      def read_hash(hash)
        record = {}
        read_plan(hash.keys).each { |field, key| record[field.name] = field.cast(hash[key]) }
        record
      end

      # Returns [Array|Hash] the value of each field of the schema, in order, in the form that the format writes it, see
      # `IOStreams::Schema::Field#render`, from the supplied record, whose keys are matched to the fields like columns,
      # or row, whose values are the fields in order. A field that it does not supply is nil. Returns a Hash by the
      # names of the fields when `keyed`, for a format whose records supply their own keys, such as JSON.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when it has a key, or more values than there are fields, that the
      # schema does not skip, see `IOStreams::Schema#check_unknown`.
      def render(row, form, keyed)
        return render_values(row, form, keyed) unless row.is_a?(::Hash)

        # When every key of the last record was a field, a record of the same size that has each of its keys has the
        # same keys, so the plan of the last record applies, and is checked while the values are taken from the record.
        if @write_fields && row.size == @write_keys.size
          out = render_record(row, form, keyed, @write_plan)
          return out if out
        end
        render_record(row, form, keyed, write_plan(row))
      end

      private

      # Returns [Array<Array(IOStreams::Schema::Field, Integer)>] each field of the columns, in the order of the fields,
      # with the position of its column, see #match.
      #
      # Raises `IOStreams::Errors::MissingHeader` before the columns are known, such as for a row of a format whose rows
      # supply their own keys, such as JSON, that is not a record.
      def matched
        @matched || raise(IOStreams::Errors::MissingHeader, "The columns must be known before a row can be read by them")
      end

      # Returns [Array] the field of each label that is one, in the order of the labels, the labels that are not
      # fields, and the position of the label of each field.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when two labels are the same field, such as `id` and `ID`.
      def find_fields(labels, noun)
        found     = []
        unknown   = []
        positions = {}.compare_by_identity
        labels.each_with_index do |label, index|
          field = @schema.field_for(label, noun)
          if field.nil?
            unknown << label
          elsif positions.key?(field)
            raise(
              IOStreams::Errors::InvalidHeader,
              "The #{noun}s #{labels[positions[field]].inspect} and #{label.inspect} are both the field " \
              "#{field.name.to_s.inspect}, so either could be meant"
            )
          else
            positions[field] = index
            found << field
          end
        end
        [found, unknown, positions]
      end

      # Returns [Array<Array(IOStreams::Schema::Field, Object)>] each field that the keys of a record read supply, in
      # the order of the fields, with its key, worked out again only when the keys change.
      def read_plan(keys)
        return @read_plan if keys == @read_keys

        found, unknown, positions = find_fields(keys, "key")
        @schema.check_columns(found, unknown, ordered: false, noun: "key")
        @read_keys = keys
        @read_plan = @schema.fields.filter_map { |field| [field, keys[positions[field]]] if positions.key?(field) }
      end

      # Returns [Array<Array(IOStreams::Schema::Field, Object, Integer)>] each field of the schema, in order, with the key
      # of a record written that supplies it, or nil when the record does not, and its position.
      def write_plan(row)
        keys = row.keys
        _found, unknown, positions = find_fields(keys, "key")
        @schema.check_unknown(unknown, noun: "key")
        @write_keys   = keys
        @write_fields = unknown.empty?
        @write_plan   = @schema.fields.each_with_index.map do |field, index|
          [field, positions.key?(field) ? keys[positions[field]] : nil, index]
        end
      end

      # Returns [Array|Hash] the rendered value of each field from the record, by the key that the plan gives for the
      # field, see #render, or nil when the record does not have one of those keys.
      def render_record(row, form, keyed, plan)
        out = keyed ? {} : ::Array.new(plan.size)
        plan.each do |field, key, index|
          value = key.nil? ? nil : row.fetch(key, MISSING)
          # Only when the keys change, so it seldom leaves the block, which JRuby does by raising an exception.
          return nil if value.equal?(MISSING)

          out[keyed ? field.name : index] = field.render(value, form)
        end
        out
      end

      # Returns [Array|Hash] the rendered value of each field from a row, whose values are the fields in order, see
      # #render, once it checks its values after the last field.
      def render_values(row, form, keyed)
        fields = @schema.fields
        @schema.check_unknown(row.drop(fields.size), noun: "value") if row.size > fields.size
        out = keyed ? {} : ::Array.new(fields.size)
        fields.each_with_index { |field, index| out[keyed ? field.name : index] = field.render(row[index], form) }
        out
      end
    end
  end
end
