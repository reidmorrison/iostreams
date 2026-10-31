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
    # skipped, unless reading keeps them, see `IOStreams::Schema#keep_extra?`, after the fields. A column is matched
    # once, when the header row is read or written, or once for each list of keys of the records, which are usually the
    # same for every record, rather than for each value.
    #
    # Each reader or writer has its own, see `IOStreams::Schema#columns`, since it holds the columns of its file.
    class Columns
      # The most sets of keys whose plans it keeps, see #read_plan and #write_plan, so that records whose keys vary, such
      # as JSON records that leave out the keys without a value, are matched once for each set of keys, while records
      # whose keys are all different do not fill the memory.
      PLANS = 64

      # The columns kept of a file whose schema does not keep them, see #extra_columns.
      NO_EXTRA = [].freeze

      # Parameters
      #   schema: [IOStreams::Schema]
      #     The fields of the columns.
      #
      #   typed: [true|false]
      #     Whether the values of the rows and records read are those of the fields, as a schema rendered them, such as
      #     the rows of a slice that says so, see `IOStreams::Slice#typed?`, so that each one is restored to the type of
      #     its field from the form that a store returned it in, see #read_value, rather than read as text. Their
      #     columns are matched to the fields either way.
      #     Default: false
      #
      #   every_field: [true|false]
      #     Whether each record and row read has every field, in the order of the fields, nil for a field whose column
      #     the file does not have, which `fieldsMatch` "superset" and "partial" accept, as the records that a contract
      #     reads do, see `IOStreams::Contract`. Without it, a record has only the fields of the columns of the file.
      #     Default: false
      #
      #   keys_vary: [true|false]
      #     Whether each record supplies its own keys, which can leave out the key of a field whose value is missing, such
      #     as JSON, see `IOStreams::Tabular::Parser::Base.keys_vary?`, so that such a key is a missing value, nil, as an
      #     empty value of CSV is, rather than a missing column: the record has the field, and a field whose value is
      #     required raises `IOStreams::Errors::InvalidValue`, as an empty value does, unless it allows blank values,
      #     while the keys that are not fields still raise as `fieldsMatch` says, as a contract reads them, see
      #     `IOStreams::Contract`. A format whose records are all keyed by the same columns, such as Parquet, checks a
      #     missing column as CSV does, and so does a schema of a file without a contract, as in v2.2.
      #     Default: false
      def initialize(schema, typed: false, every_field: false, keys_vary: false)
        @schema       = schema
        @typed        = typed
        @every_field  = every_field
        @keys_vary    = keys_vary
        # The column that each field matched, by the field, see #match, so that a contract that reads the records of
        # another schema renders the values of those columns, see `IOStreams::Schema::ContractColumns`.
        @labels       = nil
        @keep_extra   = schema.keep_extra?
        # The fields whose values the rows and records read have, those that are not skipped, see
        # `IOStreams::Schema::Field#skip?`, in order, and whether any is skipped.
        @values       = schema.fields.reject(&:skip?).freeze
        @skips        = @values.size != schema.fields.size
        # The position and key of each column of the header row read that the schema does not list, which it keeps, in
        # the order of the columns, see #extra_columns.
        @extra        = NO_EXTRA
        # Each field of the header row read, in the order of the fields, with the position of its column and its key
        # in the records read, see `IOStreams::Schema#key`, and the number of columns of the header row.
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
      # Returns [Array<String|Symbol>] the keys of the fields of the columns in the records read, in the order of the
      # fields, see #names.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when the columns do not match the fields, see
      # `IOStreams::Schema#check_columns`.
      def match(labels)
        labels = named(labels)
        found, unknown, positions = find_fields(labels, "column")
        @schema.check_columns(found, unknown, ordered: true, noun: "column")
        @matched = @schema.fields.filter_map do |field|
          [field, positions[field], @schema.key(field)] if (@every_field || positions.key?(field)) && !field.skip?
        end
        @labels  = positions.to_h { |field, index| [field, labels[index]] }.compare_by_identity
        @extra   = extra_columns(labels, positions, "column")
        @width   = labels.size
        names
      end

      # Raises as reading would when the supplied columns of a source do not match the fields, see #match, or for the keys
      # of a record of a format whose records supply their own keys, such as JSON, see #check_keys, without reading a row,
      # see `IOStreams::Stream#validate_contract!`.
      def check_meeting(labels, keyed:)
        keyed ? check_keys(labels) : match(labels)
        nil
      end

      # Returns [Array<IOStreams::Errors::InvalidHeader>] each way that the supplied columns of a source, or the keys of
      # a record of a format whose records supply their own keys, do not match the fields, see #check_meeting, not
      # raised, see `IOStreams::Stream#contract_errors`.
      def meeting_errors(labels, keyed:)
        noun   = keyed ? "key" : "column"
        labels = named(labels) unless keyed
        found, unknown, positions = find_fields(labels, noun)
        @schema.column_errors(found, unknown, ordered: !keyed, noun: noun, missing: !(keyed && @keys_vary)) +
          extra_column_errors(labels, positions, noun)
      rescue IOStreams::Errors::InvalidHeader => e
        [e]
      end

      # Returns [Array<String|Symbol>] the keys of the records that the supplied header row reads, see #found_names, or
      # an empty Array when it does not match the fields, see #meeting_errors.
      def meeting_names(labels)
        match(labels)
        found_names
      rescue IOStreams::Errors::InvalidHeader
        []
      end

      # Returns [Array<IOStreams::Errors::InvalidValue>] an error for each field whose value of the supplied values of a row
      # of the columns is not valid, see #record, which raises the first, not raised, so that a reader can report every
      # field of a bad row, see `IOStreams::InvalidRow`.
      def value_errors(values)
        matched.filter_map { |field, index| value_error(field, index && values[index]) }
      end

      # Returns [Array<IOStreams::Errors::InvalidValue>] an error for each field whose value of a record of a format
      # whose records supply their own keys, such as JSON, is not valid, see #read_hash and #value_errors.
      def hash_errors(hash)
        read_plan(hash.keys).filter_map { |field, key, _name| field && value_error(field, key.nil? ? nil : hash[key]) }
      end

      # Returns [Array<String|Symbol>] the key of each field whose values the rows and records read have, in the order of
      # the fields, see `IOStreams::Schema#key`, whatever the columns of a file are.
      def field_keys
        @values.map { |field| @schema.key(field) }
      end

      # Returns [Hash<IOStreams::Schema::Field, String|Symbol>] the column that each field matched, by the field, once the
      # columns are matched, see #match, without the fields that the file does not have.
      def labels
        @labels || raise(IOStreams::Errors::MissingHeader, "The columns must be known before they can be named")
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
        @matched = @schema.fields.each_with_index.filter_map do |field, index|
          [field, index, @schema.key(field)] unless field.skip?
        end
        @width = @schema.fields.size
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
      # The columns without a name at the end of the header row are not columns, as when reading, see #match. A column
      # that is binary text is matched by the UTF-8 text of its bytes, see #written_labels.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when a column is not a field, unless `fieldsMatch` skips it, since a
      # file that is written always has every field, or when no column is a field, so that the rows after it would have
      # no value, see `IOStreams::Schema#check_written_columns`.
      def match_written(labels)
        labels = named(written_labels(labels))
        found, unknown, positions = find_fields(labels, "column")
        @schema.check_written_columns(found, unknown, fields_in_order: @fields_in_order)
        @written       = @schema.fields.map { |field| [field, field.skip? ? nil : positions[field]] }
        @written_width = labels.size
      end

      # Returns [true|false] whether the header row of the rows written has been matched, see #match_written.
      def written?
        !@written.nil?
      end

      # Returns [Array<String|Symbol>] the keys of the fields of the columns in the records read, in the order of the
      # fields, which are their names unless the schema forms them otherwise, see `IOStreams::Schema#key`, then those of
      # the columns that it keeps, see #extra_columns, each a String of its own, so that a caller that changes one does
      # not change the field.
      def names
        names = matched.map { |_field, _index, key| key.dup }
        @extra.each { |extra| names << extra.last.dup }
        names
      end

      # Returns [Array<Integer>|nil] the position of each value of a row read whose field keeps the digits of its numbers,
      # see `IOStreams::Schema::Field#decimal?`: of the columns that the fields matched, once they are matched, see
      # #match, otherwise nil, or with `in_order: true`, of the fields in order, as a file without a header row holds
      # them, see #match_in_order, so that they are known before its first row.
      def decimal_positions(in_order: false)
        return @schema.fields.each_index.select { |index| @schema.fields[index].decimal? } if in_order
        return unless matched?

        matched.filter_map { |field, index, _key| index if index && field.decimal? }
      end

      # Returns [Array<Integer>] the position of each value of a row rendered whose field is a `string`, see #render: every
      # field, in order, a field that only holds the place of a column included.
      def text_positions
        @schema.fields.each_index.select { |index| @schema.fields[index].type == "string" }
      end

      # Returns [Array<String|Symbol>] the keys of the fields that the columns of the file matched, see #names, without
      # the fields that the file does not have, which the records read still have when every field is read, see #initialize.
      def found_names
        names = matched.filter_map { |_field, index, key| key.dup unless index.nil? }
        @extra.each { |extra| names << extra.last.dup }
        names
      end

      # Returns [Array] the values of a row read, in the order of the columns, converted to the type of each field,
      # in the order of the fields, without the columns that the schema does not list, unless it keeps them, see
      # #extra_columns, whose values follow, as they are.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when the row has values after its last column, see #check_extra.
      def row(values)
        columns = matched
        check_extra(values, @width, "column")
        row = columns.map { |field, index| read_value(field, index && values[index]) }
        @extra.each { |extra| row << values[extra.first] }
        row
      end

      # Returns [Hash] the values of a row read, in the order of the columns, converted to the type of each field, by
      # the key of the field, see `IOStreams::Schema#key`, in the order of the fields, then the values of the columns
      # that the schema keeps, see #extra_columns, as they are.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when the row has values after its last column, see #check_extra.
      def record(values)
        columns = matched
        check_extra(values, @width, "column")
        record = {}
        columns.each { |field, index, key| record[key] = read_value(field, index && values[index]) }
        @extra.each { |index, key| record[key] = values[index] }
        record
      end

      # Returns [Hash] a record read, whose keys are its columns, converted to the type of each field, by the key of
      # the field, see `IOStreams::Schema#key`, in the order of the fields, then the values of the keys that the schema
      # keeps, see #extra_columns, as they are.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when its keys do not match the fields, see
      # `IOStreams::Schema#check_columns`.
      def read_hash(hash)
        record = {}
        read_plan(hash.keys).each do |field, key, name|
          value        = hash[key] unless key.nil?
          record[name] = field ? read_value(field, value) : value
        end
        record
      end

      # Returns [Array] the value of each field, in the order of the fields, from a record read, whose keys are its
      # columns, converted to the type of each field, or nil for a field that it does not have, so that the record is a
      # row of the fields, see #match_in_order. Its keys are matched to the fields as for #read_hash.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when its keys do not match the fields, see
      # `IOStreams::Schema#check_columns`.
      # Raises ArgumentError when the schema keeps the keys that it does not list, see #extra_columns, which the rows
      # cannot hold, since each record can have other keys, which the header row of the rows does not name.
      def read_row(hash)
        if @keep_extra
          raise(ArgumentError, "A schema with extraColumns \"keep\" cannot read the rows of a format whose records " \
                               "supply their own keys, such as JSON, since each record can have keys that the header row " \
                               "of the rows does not name. Read its records, with each(:hash)")
        end

        keys = hash.keys
        plan = keys.eql?(@row_keys) ? @row_plan : row_plan(keys)
        plan.map { |field, key| read_value(field, key.nil? ? nil : hash[key]) }
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

      # Matches the keys of a record read to the fields, as #read_hash does, without reading its values, such as those of
      # the first record of a file whose records are handed on without being parsed, see
      # `IOStreams::Tabular::SchemaMapping#check_keys`.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when they do not match the fields, see `IOStreams::Schema#check_columns`.
      def check_keys(keys)
        read_plan(keys)
        nil
      end

      private

      # Returns the value of the supplied field read from a row or record, converted to the type of the field, see
      # `IOStreams::Schema::Field#cast`, or, when the values read are those of the fields, see #initialize, restored to
      # it from the form that a store returned it in, see `IOStreams::Schema::Field#restore`.
      def read_value(field, value)
        @typed ? field.restore(value) : field.cast(value)
      end

      # Returns [IOStreams::Errors::InvalidValue|nil] the error of the value of the field, or nil when it is valid.
      def value_error(field, value)
        read_value(field, value)
        nil
      rescue IOStreams::Errors::InvalidValue => e
        e
      end

      # Returns [Array] the columns of a header row up to the last one with a name, without the columns without a name
      # after it, which are blank, see `IOStreams::Utils.blank_value?`, such as the empty column after a delimiter at the end
      # of each line. A column without a name between other columns is still a column, which holds a position, so that
      # it is a column that the schema does not list.
      def named(labels)
        last = labels.rindex { |label| !IOStreams::Utils.blank_value?(label) }
        last ? labels[0..last] : []
      end

      # Returns [Array] the columns of a header row written, or the keys of a record written, see #match_written and
      # #write_plan, with each one that is binary text, whose bytes are UTF-8 that is not ASCII, as that UTF-8 text, so
      # that it is the field that it names, as a writer with a schema in IOStreams 2.2 takes it. A Symbol whose name is
      # such text, such as a binary key turned into a Symbol, is the UTF-8 text of its name, as JSON writes it, rather
      # than a Symbol of that text, which JRuby returns as the same binary Symbol, since it keeps one Symbol for the same
      # bytes. The labels written are the application's own names for the fields, which it can hold as binary, such as
      # the columns of a file read with `encoding("BINARY")` that it copies, whereas the columns of a file read with an
      # encoding are in that encoding, so they are compared as they are, see #match.
      #
      # Any other label is compared as it is, see `IOStreams::Schema#field_for`, including binary text that is not valid
      # UTF-8, which is not checked, as the bytes of the values written are not: it is a column or key that is not a
      # field, unless a field is named by its bytes, or by its ASCII letters once compared loosely, see
      # `IOStreams::Schema.match_key`.
      def written_labels(labels)
        labels.map do |label|
          text = label.is_a?(Symbol) ? label.name : label
          next label unless text.is_a?(String) && text.encoding == ::Encoding::BINARY && !text.ascii_only?

          utf8 = text.dup.force_encoding(::Encoding::UTF_8)
          next label unless utf8.valid_encoding?

          utf8
        end
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
      # A value there that is blank, see `IOStreams::Utils.blank_value?`, as a column without a name after the last column
      # is, see #named, is not data, such as the empty value after a delimiter at the end of a line, so it is ignored,
      # both when reading and when writing, so that the rows read can be written. Any other value, such as `false`, is
      # data, so it raises.
      def check_extra(values, width, last)
        return unless values.size > width

        extra = values.drop(width).reject { |value| IOStreams::Utils.blank_value?(value) }
        @schema.check_unknown(extra, noun: "value", last: last, fields_in_order: @fields_in_order)
      end

      # Returns [Array] the field of each label that is one, in the order of the labels, the labels that are not
      # fields, and the position of the label of each field.
      #
      # When `by_name`, of two labels that are the same field, the one that is its name or key, see
      # `IOStreams::Schema#key`, is the field, and the other is not a field, such as the key `"zip"` of a record written
      # that also has the key `:zip` of the field `:zip`.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when two labels are the same field, such as `id` and `ID`.
      def find_fields(labels, noun, by_name: false)
        found     = []
        unknown   = []
        positions = {}.compare_by_identity
        labels.each_with_index do |label, index|
          field = @schema.field_for(label, noun)
          # The label before it is the name of the field, so this one is not the field.
          field = nil if by_name && field && positions.key?(field) && own_label?(labels[positions[field]], field)
          if field.nil?
            unknown << label
          elsif !positions.key?(field)
            positions[field] = index
            found << field
          elsif by_name && own_label?(label, field)
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

      # Returns [Array<Array(Integer, String|Symbol)>] the position and key of each label that is not a field, in the
      # order of the labels, when the schema keeps them, see `IOStreams::Schema#keep_extra?`, each by the key that it
      # forms from the label, see `IOStreams::Schema#key_for`, without those without a name, which are blank, see
      # `IOStreams::Utils.blank_value?`, since they cannot be a key.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when a label kept has the key of a field, or of another label kept,
      # such as `Notes` and `notes` with keyType "cleansed", since a record could not hold both.
      def extra_columns(labels, positions, noun)
        return NO_EXTRA unless @keep_extra

        taken = positions.values.to_h { |index| [index, true] }
        keys  = positions.to_h { |field, index| [@schema.key(field), labels[index]] }
        extra = []
        labels.each_with_index do |label, index|
          next if taken.key?(index) || IOStreams::Utils.blank_value?(label)

          key = @schema.key_for(label)
          if keys.key?(key)
            raise(IOStreams::Errors::InvalidHeader,
                  "The #{noun}s #{keys[key].inspect} and #{label.inspect} are both the key #{key.inspect} of the records " \
                  "read, so either could be meant")
          end

          keys[key] = label
          extra << [index, key]
        end
        extra.freeze
      end

      # Returns [Array<IOStreams::Errors::InvalidHeader>] the columns that the schema keeps besides its fields, see
      # #extra_columns, that are the same key, not raised.
      def extra_column_errors(labels, positions, noun)
        extra_columns(labels, positions, noun)
        []
      rescue IOStreams::Errors::InvalidHeader => e
        [e]
      end

      # Returns [true|false] whether the label is the name or key of the field itself, see #find_fields.
      def own_label?(label, field)
        label.eql?(field.name) || label.eql?(@schema.key(field))
      end

      # Returns [Array<Array(IOStreams::Schema::Field, Object, String|Symbol)>] each field that the keys of a record
      # read supply, in the order of the fields, with the key that supplies it, and its key in the record read, see
      # `IOStreams::Schema#key`, then each key that the schema keeps, see #extra_columns, without a field, worked out
      # once for each list of keys. The keys are compared as a Hash compares them, so that a key that is only `==` to
      # another, such as `1.0` and `1`, is not taken for it.
      def read_plan(keys)
        return @read_plan if keys.eql?(@read_keys)

        @read_plan = @read_plans.fetch(keys) do
          found, unknown, positions = find_fields(keys, "key")
          @schema.check_columns(found, unknown, ordered: false, noun: "key", missing: !@keys_vary)
          @read_plans.clear if @read_plans.size >= PLANS
          plan = @schema.fields.filter_map do |field|
            next if field.skip?
            next [field, keys[positions[field]], @schema.key(field)] if positions.key?(field)

            [field, nil, @schema.key(field)] if @every_field || @keys_vary
          end
          extra_columns(keys, positions, "key").each { |index, name| plan << [nil, keys[index], name] }
          @read_plans[keys] = plan
        end
        @read_keys = keys
        @read_plan
      end

      # Returns [Array<Array(IOStreams::Schema::Field, Object)>] each field of the schema that is not skipped, in order,
      # with the key of a record read that supplies it, see #read_plan, or nil when the record does not, worked out once
      # for each list of keys. A key is never nil, since no field is the column nil, see `IOStreams::Schema#field_for`.
      def row_plan(keys)
        @row_plan = @row_plans.fetch(keys) do
          supplied = read_plan(keys).to_h { |field, key, _name| [field, key] }
          @row_plans.clear if @row_plans.size >= PLANS
          @row_plans[keys] = @values.map { |field| [field, supplied[field]] }
        end
        @row_keys = keys
        @row_plan
      end

      # Returns [Array<Array(IOStreams::Schema::Field, Object, Integer)>] each field of the schema, in order, with the key
      # of a record written that supplies it, or nil when the record does not, and its position, worked out once for
      # each list of keys, which are compared as a Hash compares them, see #read_plan. When `fieldsMatch` skips the keys
      # that are not fields, of two keys that are the same field, such as `"zip"` and `:zip`, the one that is its name
      # supplies it. A field that is skipped, see `IOStreams::Schema::Field#skip?`, takes no value, so that it is written
      # empty, whatever the key of its column holds. A key that is binary text is matched by the UTF-8 text of its bytes,
      # see #written_labels, while its value is still taken by the key itself.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when a key is not a field, unless `fieldsMatch` skips it.
      def write_plan(keys)
        @write_plan = @write_plans.fetch(keys) do
          _found, unknown, positions = find_fields(written_labels(keys), "key", by_name: @schema.skip_unknown?)
          @schema.check_unknown(unknown, noun: "key", fields_in_order: @fields_in_order)
          @write_plans.clear if @write_plans.size >= PLANS
          @write_plans[keys] = @schema.fields.each_with_index.map do |field, index|
            [field, !field.skip? && positions.key?(field) ? keys[positions[field]] : nil, index]
          end
        end
        @write_keys = keys
        @write_plan
      end

      # Returns [Array|Hash] the rendered value of each field from the record, by the key that the plan gives for the
      # field, see #render. A record of a format whose records supply their own keys, such as JSON, has no key for a
      # field that is skipped, see `IOStreams::Schema::Field#skip?`, since it has no column whose place it holds.
      def render_record(row, form, keyed, plan)
        out = keyed ? {} : ::Array.new(plan.size)
        plan.each do |field, key, index|
          next if keyed && field.skip?

          out[keyed ? field.name : index] = field.render(key.nil? ? nil : row[key], form)
        end
        out
      end

      # Returns [Array|Hash] the rendered value of each field from a row, whose values are the fields in order, or are
      # in the columns of the header row written, see #render, once it checks its values after the last field or
      # column, see #check_extra.
      def render_values(row, form, keyed)
        return render_columns(row, form, keyed) if @written
        return render_skipping(row, form, keyed) if @skips

        fields = @schema.fields
        check_extra(row, fields.size, "field")
        out = keyed ? {} : ::Array.new(fields.size)
        fields.each_with_index { |field, index| out[keyed ? field.name : index] = field.render(row[index], form) }
        out
      end

      # Returns [Array|Hash] the rendered value of each field from a row whose values are those of the fields that are
      # not skipped, see `IOStreams::Schema::Field#skip?`, in order, as the rows read have them, with an empty value for
      # each field that is skipped, or no key, see #render_record.
      def render_skipping(row, form, keyed)
        check_extra(row, @values.size, "field")
        out      = keyed ? {} : ::Array.new(@schema.fields.size)
        position = 0
        @schema.fields.each_with_index do |field, index|
          if field.skip?
            out[index] = field.render(nil, form) unless keyed
          else
            out[keyed ? field.name : index] = field.render(row[position], form)
            position += 1
          end
        end
        out
      end

      # Returns [Array|Hash] the rendered value of each field from a row whose values are in the columns of the header
      # row written, see #match_written, with an empty value for each field that is skipped, or no key, see
      # #render_record.
      def render_columns(row, form, keyed)
        check_extra(row, @written_width, "column")
        out = keyed ? {} : ::Array.new(@written.size)
        @written.each_with_index do |(field, position), index|
          next if keyed && field.skip?

          out[keyed ? field.name : index] = field.render(position.nil? ? nil : row[position], form)
        end
        out
      end
    end
  end
end
