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
    # skipped. A column is matched once, when the header row is read or written, or once for each list of keys of the
    # records, which are usually the same for every record, rather than for each value.
    #
    # Each reader or writer has its own, see `IOStreams::Schema#columns`, since it holds the columns of its file.
    class Columns
      # The most sets of keys whose plans it keeps, see #read_plan and #write_plan, so that records whose keys vary, such
      # as JSON records that leave out the keys without a value, are matched once for each set of keys, while records
      # whose keys are all different do not fill the memory.
      PLANS = 64

      def initialize(schema)
        @schema       = schema
        # Each field of the header row read, in the order of the fields, with the position of its column, and the
        # number of columns of the header row.
        @matched      = nil
        @width        = nil
        # Whether the columns are the fields in order, for a file without a header row, see #match_fields.
        @fields_in_order = false
        # Each field, in order, with the position of its column in the header row written, or nil, see #match_written,
        # and the number of columns of that header row.
        @written       = nil
        @written_width = nil
        # The plans of the records read, of the rows of the records read, and of the records written, by their keys, and
        # the keys and plan of the last of each.
        @read_plans  = {}
        @read_keys   = nil
        @read_plan   = nil
        @row_plans   = {}
        @row_keys    = nil
        @row_plan    = nil
        @write_plans = {}
        @write_keys  = nil
        @write_plan  = nil
      end

      # Matches the columns of a header row read to the fields. The columns without a name at the end of the header row,
      # such as the empty column after a delimiter at the end of the line, which a spreadsheet exports, are not columns,
      # see #named, so a value in one is a value after the last column, see #row.
      #
      # Returns [Array<String|Symbol>] the names of the fields of the columns, in the order of the fields.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when the columns do not match the fields, see
      # `IOStreams::Schema#check_columns`.
      def match(labels)
        labels = named(labels)
        found, unknown, positions = find_fields(labels, "column")
        @schema.check_columns(found, unknown, ordered: true, noun: "column")
        @matched = @schema.fields.filter_map { |field| [field, positions[field]] if positions.key?(field) }
        @width   = labels.size
        names
      end

      # Matches the columns of a file without a header row, of a format that has one, such as CSV, which are the
      # fields, in order, see `IOStreams::Schema#header?`.
      #
      # Raises ArgumentError when the schema cannot describe such a file, see `IOStreams::Schema#check_fields_in_order`.
      def match_fields
        @schema.check_fields_in_order
        @fields_in_order = true
        match_in_order
      end

      # Matches the columns of the rows of a format without a header row, such as fixed width or JSON, which are the
      # fields, in order, whatever `fieldsMatch` is, since it applies to the columns of the file, which the format
      # matches itself: by the position of each field of a fixed width file, or by the keys of each record of JSON,
      # see #read_row.
      def match_in_order
        @matched = @schema.fields.each_with_index.to_a
        @width   = @matched.size
      end

      # Returns [true|false] whether the columns of the file read are known, see #match.
      def matched?
        !@matched.nil?
      end

      # Matches the columns of a header row that is written before its rows, such as the header row read from the file
      # that is copied, see `IOStreams::Row::Writer`, so that the value of each field is taken from its column of each
      # row written after it. The header row of the file is still the names of the fields, so the rows are written in
      # the order of the fields, with no value for a field that the header row does not have.
      #
      # The columns without a name at the end of the header row are not columns, as when reading, see #match.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when a column is not a field, unless `fieldsMatch` skips it, since a
      # file that is written always has every field, or when no column is a field, so that the rows after it would have
      # no value, see `IOStreams::Schema#check_written_columns`.
      def match_written(labels)
        labels = named(labels)
        found, unknown, positions = find_fields(labels, "column")
        @schema.check_written_columns(found, unknown, fields_in_order: @fields_in_order)
        @written       = @schema.fields.map { |field| [field, positions[field]] }
        @written_width = labels.size
      end

      # Returns [true|false] whether the header row of the rows written has been matched, see #match_written.
      def written?
        !@written.nil?
      end

      # Returns [Array<String|Symbol>] the names of the fields of the columns, in the order of the fields, each a String
      # of its own, so that a caller that changes one does not change the field.
      def names
        matched.map { |field, _index| field.name.dup }
      end

      # Returns [Array] the values of a row read, in the order of the columns, converted to the type of each field,
      # in the order of the fields, without the columns that the schema does not list.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when the row has values after its last column, see #check_extra.
      def row(values)
        columns = matched
        check_extra(values, @width, "column")
        columns.map { |field, index| field.cast(values[index]) }
      end

      # Returns [Hash] the values of a row read, in the order of the columns, converted to the type of each field, by
      # the name of the field, in the order of the fields.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when the row has values after its last column, see #check_extra.
      def record(values)
        columns = matched
        check_extra(values, @width, "column")
        record = {}
        columns.each { |field, index| record[field.name] = field.cast(values[index]) }
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

      # Returns [Array] the value of each field, in the order of the fields, from a record read, whose keys are its
      # columns, converted to the type of each field, or nil for a field that it does not have, so that the record is a
      # row of the fields, see #match_in_order. Its keys are matched to the fields as for #read_hash.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when its keys do not match the fields, see
      # `IOStreams::Schema#check_columns`.
      def read_row(hash)
        keys = hash.keys
        plan = keys.eql?(@row_keys) ? @row_plan : row_plan(keys)
        plan.map { |field, key| key.nil? ? nil : field.cast(hash[key]) }
      end

      # Returns [Array|Hash] the value of each field of the schema, in order, in the form that the format writes it, see
      # `IOStreams::Schema::Field#render`, from the supplied record, whose keys are matched to the fields like columns,
      # or row, whose values are the fields in order, or are in the columns of the header row written, see
      # #match_written. A field that it does not supply is nil. Returns a Hash by the names of the fields when `keyed`,
      # for a format whose records supply their own keys, such as JSON.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when it has a key, or more values than there are fields or columns,
      # that the schema does not skip, see `IOStreams::Schema#check_unknown`.
      # Raises `IOStreams::Errors::TypeMismatch` when it is neither a Hash nor an Array.
      def render(row, form, keyed)
        return render_values(row, form, keyed) if row.is_a?(::Array)
        unless row.is_a?(::Hash)
          raise(IOStreams::Errors::TypeMismatch,
                "Don't know how to write a #{row.class.name} with a schema, which writes a Hash or an Array")
        end

        keys = row.keys
        render_record(row, form, keyed, keys.eql?(@write_keys) ? @write_plan : write_plan(keys))
      end

      # Returns nil, the line of a blank record or row, which a file writes as a blank line, see
      # `IOStreams::Tabular#render`.
      #
      # Raises `IOStreams::Errors::InvalidValue` for a field that is required, since a blank record has no value for it.
      def render_blank
        @schema.fields.each { |field| field.cast(nil) if field.required? }
        nil
      end

      private

      # Returns [Array] the columns of a header row up to the last one with a name, without the columns without a name
      # after it, which are blank, such as the empty column after a delimiter at the end of each line. A column without
      # a name between other columns is still a column, which holds a position, so that it is a column that the schema
      # does not list.
      def named(labels)
        last = labels.rindex { |label| !IOStreams::Utils.blank?(label) }
        last ? labels[0..last] : []
      end

      # Returns [Array<Array(IOStreams::Schema::Field, Integer)>] each field of the columns, in the order of the fields,
      # with the position of its column, see #match.
      #
      # Raises `IOStreams::Errors::MissingHeader` before the columns are known.
      def matched
        @matched || raise(IOStreams::Errors::MissingHeader, "The columns must be known before a row can be read by them")
      end

      # Raises `IOStreams::Errors::InvalidHeader` when a row read or written has values after its `width`, the last column
      # of its header row, or the last field of a file without one, which `last` names, unless `fieldsMatch` skips them,
      # since they are not the value of any field, such as when a value read holds a delimiter that is not quoted.
      #
      # A value there that is nil, or text that is blank, is not data, such as the empty value after a delimiter at the
      # end of a line, so it is ignored, both when reading and when writing, so that the rows read can be written. Any
      # other value, such as `false`, is data, so it raises.
      def check_extra(values, width, last)
        return unless values.size > width

        extra = values.drop(width).reject { |value| value.nil? || (value.is_a?(String) && IOStreams::Utils.blank?(value)) }
        @schema.check_unknown(extra, noun: "value", last: last, fields_in_order: @fields_in_order)
      end

      # Returns [Array] the field of each label that is one, in the order of the labels, the labels that are not
      # fields, and the position of the label of each field.
      #
      # When `by_name`, of two labels that are the same field, the one that is its name is the field, and the other is
      # not a field, such as the key `"zip"` of a record written that also has the key `:zip` of the field `:zip`.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when two labels are the same field, such as `id` and `ID`.
      def find_fields(labels, noun, by_name: false)
        found     = []
        unknown   = []
        positions = {}.compare_by_identity
        labels.each_with_index do |label, index|
          field = @schema.field_for(label, noun)
          # The label before it is the name of the field, so this one is not the field.
          field = nil if by_name && field && positions.key?(field) && labels[positions[field]].eql?(field.name)
          if field.nil?
            unknown << label
          elsif !positions.key?(field)
            positions[field] = index
            found << field
          elsif by_name && label.eql?(field.name)
            unknown << labels[positions[field]]
            positions[field] = index
          else
            raise(
              IOStreams::Errors::InvalidHeader,
              "The #{noun}s #{labels[positions[field]].inspect} and #{label.inspect} are both the field " \
              "#{field.name.to_s.inspect}, so either could be meant"
            )
          end
        end
        [found, unknown, positions]
      end

      # Returns [Array<Array(IOStreams::Schema::Field, Object)>] each field that the keys of a record read supply, in
      # the order of the fields, with its key, worked out once for each list of keys. The keys are compared as a Hash
      # compares them, so that a key that is only `==` to another, such as `1.0` and `1`, is not taken for it.
      def read_plan(keys)
        return @read_plan if keys.eql?(@read_keys)

        @read_plan = @read_plans.fetch(keys) do
          found, unknown, positions = find_fields(keys, "key")
          @schema.check_columns(found, unknown, ordered: false, noun: "key")
          @read_plans.clear if @read_plans.size >= PLANS
          @read_plans[keys] = @schema.fields.filter_map { |field| [field, keys[positions[field]]] if positions.key?(field) }
        end
        @read_keys = keys
        @read_plan
      end

      # Returns [Array<Array(IOStreams::Schema::Field, Object)>] each field of the schema, in order, with the key of a
      # record read that supplies it, see #read_plan, or nil when the record does not, worked out once for each list of
      # keys. A key is never nil, since no field is the column nil, see `IOStreams::Schema#field_for`.
      def row_plan(keys)
        @row_plan = @row_plans.fetch(keys) do
          supplied = read_plan(keys).to_h
          @row_plans.clear if @row_plans.size >= PLANS
          @row_plans[keys] = @schema.fields.map { |field| [field, supplied[field]] }
        end
        @row_keys = keys
        @row_plan
      end

      # Returns [Array<Array(IOStreams::Schema::Field, Object, Integer)>] each field of the schema, in order, with the key
      # of a record written that supplies it, or nil when the record does not, and its position, worked out once for
      # each list of keys, which are compared as a Hash compares them, see #read_plan. When `fieldsMatch` skips the keys
      # that are not fields, of two keys that are the same field, the one that is its name supplies it, as a layout of
      # the deprecated format options always took it.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when a key is not a field, unless `fieldsMatch` skips it.
      def write_plan(keys)
        @write_plan = @write_plans.fetch(keys) do
          _found, unknown, positions = find_fields(keys, "key", by_name: @schema.skip_unknown?)
          @schema.check_unknown(unknown, noun: "key", fields_in_order: @fields_in_order)
          @write_plans.clear if @write_plans.size >= PLANS
          @write_plans[keys] = @schema.fields.each_with_index.map do |field, index|
            [field, positions.key?(field) ? keys[positions[field]] : nil, index]
          end
        end
        @write_keys = keys
        @write_plan
      end

      # Returns [Array|Hash] the rendered value of each field from the record, by the key that the plan gives for the
      # field, see #render.
      def render_record(row, form, keyed, plan)
        out = keyed ? {} : ::Array.new(plan.size)
        plan.each do |field, key, index|
          out[keyed ? field.name : index] = field.render(key.nil? ? nil : row[key], form)
        end
        out
      end

      # Returns [Array|Hash] the rendered value of each field from a row, whose values are the fields in order, or are
      # in the columns of the header row written, see #render, once it checks its values after the last field or
      # column, see #check_extra.
      def render_values(row, form, keyed)
        return render_columns(row, form, keyed) if @written

        fields = @schema.fields
        check_extra(row, fields.size, "field")
        out = keyed ? {} : ::Array.new(fields.size)
        fields.each_with_index { |field, index| out[keyed ? field.name : index] = field.render(row[index], form) }
        out
      end

      # Returns [Array|Hash] the rendered value of each field from a row whose values are in the columns of the header
      # row written, see #match_written.
      def render_columns(row, form, keyed)
        check_extra(row, @written_width, "column")
        out = keyed ? {} : ::Array.new(@written.size)
        @written.each_with_index do |(field, position), index|
          out[keyed ? field.name : index] = field.render(position.nil? ? nil : row[position], form)
        end
        out
      end
    end
  end
end
