# frozen_string_literal: true

module IOStreams
  class Tabular
    # Maps the columns of a file to the fields of its schema, see `IOStreams::Tabular::Mapping`: the columns of its header
    # row, or the keys of each record of a format of keyed records, such as JSON, are matched to the fields once, see
    # `IOStreams::Schema::Columns`, which converts the values of each row and record read to the types of the fields, by
    # their names, and renders those written. The columns of the rows of a file without a header row are the fields, in
    # order, see `IOStreams::Schema#header?`, including those of a format whose records supply their own keys, whose rows
    # are the values of every field of each record.
    #
    # The header keeps the header row as it was read, so that another Tabular with the same schema, such as one that
    # reads the rest of the file elsewhere, matches the same columns with `read_header(header.columns)`.
    class SchemaMapping < Mapping
      # Parameters:
      #   schema: [IOStreams::Schema]
      #     The fields of the rows and records.
      #
      #   headerless: [true|false|nil]
      #     Whether the rows have no header row, when the format has one, such as CSV, whatever the schema says, see
      #     `IOStreams::Schema#header?`: true for rows that do not start with one, false for rows that do, such as those
      #     of a slice, which says whether it carries one, see `IOStreams::Tabular#initialize`.
      #     Default: nil, as the schema says.
      #
      #   typed: [true|false]
      #     Whether the values of the rows and records read are already those of the fields, such as those of a slice that
      #     says so, see `IOStreams::Slice#typed?`, so that they are matched to the fields but not converted again, see
      #     `IOStreams::Schema::Columns#initialize`.
      #     Default: false
      #
      #   See `IOStreams::Tabular::Mapping#initialize` for the others.
      #
      # Raises ArgumentError when the rows of a format with a header row, such as CSV, have none, and the schema cannot
      # describe them, see `IOStreams::Schema#check_fields_in_order`.
      def initialize(schema, header:, parser:, format:, blank_rows: true, headerless: nil, typed: false)
        super(header: header, parser: parser, format: format, blank_rows: blank_rows)
        @schema          = schema
        @columns         = schema.columns(typed: typed)
        @requires_header = parser.requires_header? && (headerless.nil? ? schema.header? : !headerless)
        # Whether each row is a record whose keys are its columns, such as JSON, rather than the values in the order of
        # the columns, see `IOStreams::Tabular::Parser::Base.keyed?`, and the form in which the format writes the values
        # of the fields.
        @keyed           = parser.class.keyed?
        @form            = parser.class.value_form
        # The columns of the rows of a file without a header row are the fields, in order: of a format with one whose
        # rows have none, see `IOStreams::Schema#check_fields_in_order`, or of a format without one, such as fixed width,
        # or JSON, whose rows are the values of the fields of its records.
        if parser.requires_header?
          @columns.match_fields unless @requires_header
        else
          @columns.match_in_order
        end
        # Whether the names of the fields have been read as the header row of the rows of a file without one, see
        # #rows_header?.
        @names_read = false
        # Whether the keys of the first record of a format of keyed records have been matched to the fields, see
        # #check_keys.
        @keys_checked = false
      end

      # Returns [true|false] whether the file has a header row: when its format has one, such as CSV, and the rows have
      # one, as `headerless:` says, see #initialize, otherwise as the schema says, see `IOStreams::Schema#header?`.
      def requires_header?
        @requires_header
      end

      # Returns [true|false] whether the header row is still to be read, see #read_header: until its columns are
      # matched to the fields, for a file with a header row.
      def header?
        @requires_header && !@columns.matched?
      end

      # Returns [true|false] whether the rows read start with a header row, see `IOStreams::Tabular#rows_header?`: the
      # header row of a file with one, until it is read, see #header?, or for a file without one, the names of the
      # fields, which are the columns of its rows, until they are read, see #read_rows_header, so that the rows of every
      # file start with a header row.
      def rows_header?
        @requires_header ? header? : !@names_read
      end

      # Raises ArgumentError: the header row is not cleansed with a schema, whose fields name the keys of the records read
      # instead, which the columns of the header row are matched to, so that the header keeps the header row as it was
      # read, for `read_header(header.columns)`, see above.
      def cleanse_header!
        raise(ArgumentError, "The header row cannot be cleansed with a schema, since the keys of its records are the " \
                             "names of its fields, which the columns of the header row are matched to, see " \
                             "IOStreams::Schema#field_for")
      end

      # Returns [true] the keys of the records read are the names of the fields, see `IOStreams::Tabular#field_names?`.
      def field_names?
        true
      end

      # Returns [Array<String|Symbol>] the names of the fields of a file without a header row, which are the columns of
      # its rows, see `IOStreams::Tabular#headerless_columns`.
      # Returns nil for a file with a header row.
      def headerless_columns
        @columns.names if @columns.matched? && !@requires_header
      end

      # Returns [false] the schema gives the columns of the rows and records written.
      def columns_from_first_row?
        false
      end

      # Returns [false] the schema writes the header row of a file with one, the names of its fields, before the rows
      # written, see `IOStreams::Tabular#start_rows`, so that every row written is a row of the values of the fields, in
      # order, as for a file without a header row.
      def first_row_header?
        false
      end

      # Returns [true] a header row written before the rows after it, such as the header row that
      # `IOStreams::Stream#each(:array)` yields, an `IOStreams::Row::HeaderRow`, gives the columns of those rows, see
      # #take_columns, rather than being written as a row, since the header row of the file is the names of the fields,
      # which the schema writes, or the file has none.
      def columns_from_header_row?
        true
      end

      # Takes the columns of the rows written after them from a header row written before them, see
      # #columns_from_header_row?, once they are matched to the fields, see `IOStreams::Schema::Columns#match_written`,
      # without a line, since the header row of the file is the names of the fields, which the schema writes, see
      # #render_header.
      def take_columns(columns)
        @columns.match_written(columns)
        nil
      end

      # Returns [Array] the header row parsed from the line, once its columns are matched to the fields, see
      # `IOStreams::Schema::Columns#match`.
      # Returns nil when the line is blank, or the file has no header row, see #requires_header?, such as with a schema
      # whose `header` is false, whose lines are all rows.
      def parse_header(line)
        match_header(line)&.first
      end

      # Matches the columns of the header row to the fields, see #parse_header.
      #
      # Returns [Array<String|Symbol>] the names of the fields of its columns, in the order of the fields.
      # Returns nil when the line is blank, or the file has no header row.
      def read_header(line)
        match_header(line)&.last
      end

      # Returns [false] the fields of the schema name the columns of the rows, see `IOStreams::Tabular#unnamed_columns?`.
      def unnamed_columns?
        false
      end

      # Matches the keys of the first record of a format of keyed records, such as JSON or Parquet, that is not blank to
      # the fields, as #record_parse would, without converting its values, so that a file whose records do not match the
      # schema raises before its rows are handed on without being parsed, see `IOStreams::Tabular#read_line`. The keys of
      # the other records are matched when they are parsed. A row already read, an Array, has no keys.
      #
      # Raises `IOStreams::Errors::InvalidHeader` when they do not match, see `IOStreams::Schema::Columns#check_keys`.
      def check_keys(line)
        return if !@keyed || @keys_checked

        values = parse(line)
        return if values.nil?

        @columns.check_keys(values.keys) if values.is_a?(::Hash)
        @keys_checked = true
        nil
      end

      # Returns [Array<String|Symbol>] the header row of the rows of a file without one, which is not a line of the
      # file, see #rows_header?: the names of the fields, which are the columns of its rows, whatever the line is.
      def read_rows_header(_line)
        @names_read = true
        @columns.names
      end

      # Returns [Array] the values of the fields of the line, converted to their types, in the order of the fields: of
      # its columns, or, for a format whose records supply their own keys, such as JSON, of every field, nil for a key
      # that its record does not have, see `IOStreams::Schema::Columns#read_row`.
      # Returns nil if the line is blank.
      def row_parse(line)
        values = parse(line)
        return if values.nil?

        values.is_a?(::Hash) ? @columns.read_row(values) : @columns.row(values)
      end

      # Returns [Hash] the record of the line, converted to the types of the fields, by the names of the fields. The
      # record of a row already read, an Array, is by the columns of the rows, see #row_parse.
      # Returns nil if the line is blank.
      def record_parse(line)
        values = parse(line)
        return if values.nil?

        values.is_a?(::Hash) ? @columns.read_hash(values) : @columns.record(values)
      end

      # Returns [String|Array|Hash] the line that the parser renders for the row or record, with the value of each field
      # in the form of its field that the format writes, see `IOStreams::Schema::Field#render`, in the order of the
      # fields, see `IOStreams::Schema::Columns#render`.
      #
      # Returns nil for a blank row, which is written as a blank line, see #render_blank.
      def render(row)
        return @columns.render_blank if IOStreams::Utils.blank?(row)

        render_fields(row)
      end

      # Returns [String|Array|Hash] the line that the parser renders for the value of each field of a row or record that
      # is not blank, see #render, even when it supplies none of them.
      def render_fields(row)
        @parser.render(@columns.render(row, @form, @keyed))
      end

      # Returns nil, the line of a blank row or record, which is written as a blank line.
      #
      # Raises `IOStreams::Errors::InvalidValue` for a field that is required, since a blank row has no value for it.
      def render_blank
        @columns.render_blank
      end

      # Returns [String] the header row of the file: the names of its fields, once the columns supplied, if any, are
      # matched to the fields, so that the value of each field is taken from its column of the rows rendered after it,
      # see `IOStreams::Schema::Columns#match_written`.
      # Returns nil when the file has no header row.
      def render_header(columns = nil)
        @columns.match_written(columns) if columns
        return unless @requires_header

        @parser.render(@schema.fields.map { |field| field.name.to_s })
      end

      private

      # Returns [Array(Array, Array)] the header row parsed from the line, which the header keeps as it was read, and the
      # names of the fields of its columns, once they are matched to the fields, or nil when the line is blank, or the
      # format has no header row.
      def match_header(line)
        return unless @requires_header

        columns = parse(line)
        return if columns.nil?

        names          = @columns.match(columns)
        header.columns = columns
        [columns, names]
      end
    end
  end
end
