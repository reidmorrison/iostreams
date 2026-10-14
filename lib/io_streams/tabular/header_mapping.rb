# frozen_string_literal: true

module IOStreams
  class Tabular
    # Maps the columns of a file without a schema, see `IOStreams::Tabular::Mapping`, by its header: the columns of its
    # header row, or the columns supplied in place of one, which a format of keyed records, such as JSON, does not need.
    #
    # Applies the column options of the header, `allowed_columns`, `required_columns` and `skip_unknown`, which are
    # deprecated, to every input when reading: the header row, the columns supplied, and the keys of each record of a
    # format without a header row. Unless `IOStreams.enforce_column_restrictions?`, they are only applied to a header row
    # that is cleansed, and otherwise a warning is logged, once, when applying them would change the result.
    class HeaderMapping < Mapping
      # Parameters:
      #   cleanse: [true|false]
      #     Whether to cleanse the header row read, see `IOStreams::Tabular::Header#cleanse!`, as the `cleanse_header`
      #     option of `IOStreams::Tabular.new` says, which #read_header, #restrict_columns and #read_record apply unless
      #     they are told otherwise.
      #     Default: true
      #
      #   See `IOStreams::Tabular::Mapping#initialize` for the others.
      def initialize(header:, parser:, format:, cleanse: true)
        super(header: header, parser: parser, format: format)
        @cleanse         = cleanse
        @requires_header = parser.requires_header?
        @keyed           = parser.class.keyed?
        @supplied        = !header.columns.nil?
        @warned          = false
      end

      # Returns [true|false] whether the file has a header row: when its format has one, such as CSV.
      def requires_header?
        @requires_header
      end

      # Returns [true|false] whether the header row is still to be read, see #read_header: for a format with one, until
      # the columns are known.
      def header?
        @requires_header && IOStreams::Utils.blank?(header.columns)
      end

      # Returns [false] the keys of the records read are the columns of the file, see `IOStreams::Tabular#field_names?`.
      def field_names?
        false
      end

      # Returns [nil] only the fields of a schema are the columns of a file without a header row, see
      # `IOStreams::Tabular#headerless_columns`.
      def headerless_columns
        nil
      end

      # Returns [true|false] whether the columns were supplied, in place of a header row.
      def columns_supplied?
        @supplied
      end

      # Returns [true|false] whether a writer takes the columns from the first row or record written, since they are not
      # known yet, see #header?.
      def columns_from_first_row?
        header?
      end

      # Returns [true|false] whether the next row written is the header row, which gives the columns, see
      # #columns_from_first_row?.
      def first_row_header?
        header?
      end

      # Returns [true|false] whether the header row written before the rows copied from a file with one gives the
      # columns of the rows, see #render_header, rather than being written as a row: for a format without a header row,
      # such as JSON, unless the columns are known, which it does not replace.
      def columns_from_header_row?
        !@requires_header && header.columns.nil?
      end

      # Returns [Array] the header row parsed from the line, which becomes the columns of the header, before it is
      # cleansed, see `IOStreams::Tabular#parse_header`.
      # Returns nil when the line is blank, or the format has no header row.
      def parse_header(line)
        return if IOStreams::Utils.blank?(line) || !@requires_header

        columns        = @parser.parse(line)
        header.columns = columns
        columns
      end

      # Parses the header row, see #parse_header, then cleanses its columns when `cleanse` is truthy, otherwise applies
      # the column restrictions to them as they are, see #restrict_columns. For a format without a header row, such as
      # the layout of a fixed width file, they apply to the columns supplied.
      #
      # Returns [Array] the header row as read, before it is cleansed, or nil when the line is blank, or the format does
      # not have a header row.
      def read_header(line, cleanse: @cleanse)
        columns = parse_header(line)
        cleanse ? header.cleanse! : restrict_columns(rename: false)
        columns
      end

      # Applies the column restrictions to the columns once they are known, such as the columns supplied in place of a
      # header row, renaming them when `rename`, see `IOStreams::Tabular::Header#cleanse!`.
      def restrict_columns(rename: @cleanse)
        return if header? || !header.restricted?
        return header.cleanse!(rename: rename) if IOStreams.enforce_column_restrictions?

        warn_restriction("header row") if !@warned && header.cleanse_changes?(rename: rename)
      end

      # Returns [Array|Hash] the values of the line as the parser parses them, or nil when it is blank.
      def row_parse(line)
        parse(line)
      end

      # Returns [Hash] the record of the line, by the columns, see `IOStreams::Tabular::Header#to_hash`, or nil when it
      # is blank.
      def record_parse(line)
        values = parse(line)
        header.to_hash(values) if values
      end

      # Returns [Hash] the record of the line, see #record_parse, with the column restrictions applied to its keys for a
      # format without a header row, such as JSON, whose records each supply their own keys, renaming them when
      # `rename`, see `IOStreams::Tabular::Header#restrict_hash`.
      # Returns nil if the line is blank.
      def read_record(line, rename: @cleanse)
        record = record_parse(line)
        return record unless record.is_a?(::Hash) && header.restricted? && header.columns.nil?
        return header.restrict_hash(record, rename: rename) if IOStreams.enforce_column_restrictions?

        # Once warned, the remaining records are not checked.
        warn_restriction("records") if !@warned && header.restrict_hash_changes?(record, rename: rename)
        record
      end

      # Returns [String|Array|Hash] the line that the parser renders for the row or record: a record by the columns, see
      # `IOStreams::Tabular::Header#to_hash`, for a format of keyed records, such as JSON, otherwise its values in the
      # order of the columns, see `IOStreams::Tabular::Header#to_array`, see `IOStreams::Tabular::Parser::Base.keyed?`.
      # Returns nil for a blank row, which is written as a blank line.
      def render(row)
        return if IOStreams::Utils.blank?(row)

        @parser.render(@keyed ? header.to_hash(row) : header.to_array(row))
      end

      # Returns [String] the header row of the columns, once the columns supplied to it, if any, become the columns, such
      # as the first row written when the columns were not supplied in place of a header row.
      # Returns nil when the format has no header row.
      #
      # Raises `IOStreams::Errors::MissingHeader` when the columns are not known.
      def render_header(columns = nil)
        header.columns = columns if columns
        return unless @requires_header

        if IOStreams::Utils.blank?(header.columns)
          raise(
            Errors::MissingHeader,
            "Header columns must be set before attempting to render a header for format: #{@format.inspect}"
          )
        end

        @parser.render(header.columns)
      end

      private

      # Logs a warning that the column restrictions are not applied, once, since the same columns usually apply
      # to every record.
      def warn_restriction(input)
        return if @warned

        @warned = true
        IOStreams.logger&.warn(
          "allowed_columns and required_columns are not applied to this input since " \
          "`IOStreams.enforce_column_restrictions` is false, but would change the #{input} read."
        )
      end
    end
  end
end
