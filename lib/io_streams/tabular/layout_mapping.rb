# frozen_string_literal: true

module IOStreams
  class Tabular
    # Maps the columns of a fixed width file whose layout is supplied with the format options, which are deprecated, see
    # `IOStreams::Tabular::Mapping`: like a file without a schema, see `IOStreams::Tabular::HeaderMapping`, so that the
    # columns supplied and the column options still apply to its records, as they did before the layout was deprecated,
    # while the schema that the layout is translated into, see `IOStreams::Tabular::Parser::Fixed.schema`, reads and
    # renders its values, see `IOStreams::Tabular::SchemaMapping`.
    #
    # The keys of its records are the keys of the layout, or the columns supplied, and its rows are their values, in
    # order.
    class LayoutMapping < HeaderMapping
      # Parameters:
      #   schema: [IOStreams::Schema]
      #     The schema of the layout, whose fields are the columns of the layout, by their keys.
      #
      #   See `IOStreams::Tabular::HeaderMapping#initialize` for the others.
      def initialize(schema, header:, parser:, format:, cleanse: true)
        super(header: header, parser: parser, format: format, cleanse: cleanse)
        @fields       = SchemaMapping.new(schema, header: header, parser: parser, format: format)
        # Whether the columns of the rows have been read as their header row, see #rows_header?.
        @columns_read = false
      end

      # Returns [Array<String|Symbol>] the columns of the rows, see #row_parse: the keys of the layout, or the columns
      # supplied, as they are supplied.
      def headerless_columns
        @rows ? @rows.columns.dup : @fields.headerless_columns
      end

      # Returns [true|false] whether the rows read start with a header row: the keys of the layout, which are the columns
      # of the rows, see #headerless_columns, until they are read, see #read_rows_header, since a fixed width file has
      # none of its own. False when the columns were supplied, which name the values of the rows instead, as for any
      # other format, see `IOStreams::Tabular::HeaderMapping#rows_header?`.
      def rows_header?
        !(@columns_read || columns_supplied?)
      end

      # Returns [Array<String|Symbol>] the columns of the rows, see #headerless_columns, as the header row of the rows,
      # whatever the line is, since a fixed width file has none of its own to read, see #rows_header?.
      def read_rows_header(_line)
        @columns_read = true
        headerless_columns
      end

      # Returns [Array] the values of the line, in the order of the columns of its rows: the fields of the layout, see
      # `IOStreams::Tabular::SchemaMapping#row_parse`, or the columns supplied, as they are supplied, whose values are
      # those of the keys of the layout that they name, see `IOStreams::Tabular::Header#to_array`, since the column
      # options never change a row. Returns nil when it is blank.
      def row_parse(line)
        return @fields.row_parse(line) unless @rows

        record = @fields.record_parse(line)
        @rows.to_array(record) if record
      end

      # Returns [Hash] the record of the line, see `IOStreams::Tabular::SchemaMapping#record_parse`, by the columns
      # supplied, see `IOStreams::Tabular::Header#to_hash`, otherwise by the keys of the layout, or nil when it is blank.
      # The record of a row already read, an Array, is by the columns of the rows, see #row_parse.
      def record_parse(line)
        if @rows && line.is_a?(::Array)
          row = parse(line)
          return row && header.to_hash(row)
        end

        record = @fields.record_parse(line)
        record.nil? || header.columns.nil? ? record : header.to_hash(record)
      end

      # Returns [String] the line of the record or row, see `IOStreams::Tabular::SchemaMapping#render`, whose values are
      # in the columns supplied, see `IOStreams::Tabular::Header#to_hash`, otherwise by the keys of the layout.
      # Returns nil for a blank row.
      def render(row)
        return @fields.render_blank if IOStreams::Utils.blank?(row)

        @fields.render_fields(header.columns.nil? ? row : header.to_hash(row))
      end

      # Returns nil, since a fixed width file has no header row, once the columns supplied, if any, are matched to the
      # fields of the layout, see `IOStreams::Tabular::SchemaMapping#render_header`.
      def render_header(columns = nil)
        @fields.render_header(columns)
      end

      # Takes the columns of the rows written after them from a header row written before them, matched to the fields of
      # the layout, see `IOStreams::Tabular::SchemaMapping#take_columns`.
      def take_columns(columns)
        @fields.take_columns(columns)
      end
    end
  end
end
