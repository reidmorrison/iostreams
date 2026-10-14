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
        @fields = SchemaMapping.new(schema, header: header, parser: parser, format: format)
      end

      # Returns [Array<String|Symbol>] the columns of the rows, see #row_parse: the keys of the layout, or the columns
      # supplied, as they are supplied, see `IOStreams::Tabular#headerless_columns`.
      def headerless_columns
        @rows ? @rows.columns.dup : @fields.headerless_columns
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
        return header.to_hash(line) if @rows && line.is_a?(::Array)

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
    end
  end
end
