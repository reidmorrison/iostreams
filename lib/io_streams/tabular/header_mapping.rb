# frozen_string_literal: true

module IOStreams
  class Tabular
    # Maps the columns of a file without a schema, see `IOStreams::Tabular::Mapping`, by its header: the columns of its
    # header row, once cleansed, see `IOStreams::Tabular::Header#cleanse!`, which the records of a format of keyed
    # records, such as JSON, do not need, but its rows do: the keys of its first record are the columns of its rows, which
    # it reads as their header row, see #read_header.
    class HeaderMapping < Mapping
      # Parameters:
      #   headerless: [true|false|nil]
      #     Whether the rows have no header row, when the format has one, such as CSV: true for rows that do not start
      #     with one, such as those of a slice without one, see `IOStreams::Tabular#initialize`, whose columns nothing
      #     then names, see #unnamed_columns?.
      #     Default: nil, as the format says.
      #
      #   See `IOStreams::Tabular::Mapping#initialize` for the others.
      def initialize(header:, parser:, format:, blank_rows: true, headerless: nil)
        super(header: header, parser: parser, format: format, blank_rows: blank_rows)
        @requires_header = !headerless && parser.requires_header?
        @keyed           = parser.class.keyed?
        # The keys of the first record of a format of keyed records, which are the columns of its rows, see
        # #read_header, whose plans it keeps, see #row_plan.
        @keys            = nil
        clear_row_plans
      end

      # Returns [true|false] whether the file has a header row: when its format has one, such as CSV, unless the rows do
      # not start with one, see #initialize.
      def requires_header?
        @requires_header
      end

      # Returns [true|false] whether the header row is still to be read, see #read_header: for a format with one, until
      # the columns are known.
      def header?
        @requires_header && IOStreams::Utils.blank?(header.columns)
      end

      # Returns [true|false] whether the rows read start with a header row, which names the column of each value of the
      # rows after it: the header row of a file with one, until it is read, see #header?, or for a format of keyed
      # records, such as JSON, the keys of its first record, until they are read, see #read_rows_header.
      def rows_header?
        header? || (@keyed && @keys.nil?)
      end

      # Returns [Array<String>] the columns of the header row once they are cleansed, see
      # `IOStreams::Tabular::Header#cleanse!`.
      def cleanse_header!
        header.cleanse!
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

      # Returns [true|false] whether a writer takes the columns from the first row or record written, since they are not
      # known yet, see #header?.
      def columns_from_first_row?
        header?
      end

      # Returns [true|false] whether the next row written is the header row, which gives the columns, see
      # #columns_from_first_row?, also for a format of keyed records, such as JSON, whose rows have no keys of their own,
      # so that the rows that each(:array) reads from it can be written, although its records keep their own keys.
      def first_row_header?
        header? || (@keyed && IOStreams::Utils.blank?(header.columns))
      end

      # Returns [true|false] whether the header row written before the rows copied from a file with one gives the
      # columns of the rows, see #take_columns, rather than being written as a row: for a format without a header row,
      # such as JSON, unless the columns are known, which it does not replace.
      def columns_from_header_row?
        !@requires_header && header.columns.nil?
      end

      # Takes the columns of the rows written after them from a header row written before them, see
      # #columns_from_header_row?, which become the columns, see #render_header, without a line, since a format that
      # takes them, such as JSON, has no header row.
      #
      # Raises `IOStreams::Errors::MissingHeader` when the columns of a format of keyed records are empty.
      def take_columns(columns)
        render_header(columns)
        nil
      end

      # Returns [true|false] whether nothing names the columns of the rows: for rows without a header row that have no
      # keys, such as those of `:text`, or of a slice of CSV without a header row, see #initialize, since without a
      # schema nothing else would, see `IOStreams::Tabular#unnamed_columns?`.
      def unnamed_columns?
        !@requires_header && !@keyed
      end

      # Returns [Array] the header row parsed from the line, which becomes the columns of the header, before it is
      # cleansed, see `IOStreams::Tabular#parse_header`. For a format of keyed records, such as JSON, the keys of the
      # record of the line, or of a row of keys, which become the columns of the rows, see #parse_keys.
      # Returns nil when the line is blank, or the format has no header row.
      def parse_header(line)
        return parse_keys(line) if @keyed
        return unless @requires_header

        columns = parse_columns(line)
        return if columns.nil?

        header.columns = columns
        columns
      end

      # Parses the header row, see #parse_header, then cleanses its columns. The keys of a format of keyed records are
      # kept as they are, as the keys of its records are, see #record_parse.
      #
      # Returns [Array] the header row as read, before it is cleansed, or nil when the line is blank, or the format does
      # not have a header row.
      def read_header(line)
        columns = parse_header(line)
        header.cleanse! unless @keyed
        columns
      end

      # Returns [Array] the header row of the rows, which is not a line of its own, see #rows_header?: the keys of the
      # record of the line of a format of keyed records, such as JSON, see #read_header, or nil when the line is blank,
      # such as a JSON line of `null`, which gives no keys.
      def read_rows_header(line)
        read_header(line)
      end

      # Returns [Array] the values of the line as the parser parses them, or nil when it is blank. For a format of keyed
      # records, such as JSON, the values of the record of the line in the order of the columns of the rows, see
      # #row_of, or nil for a record without keys, such as `{}`, or a row already read, an Array, as it is.
      #
      # Raises `IOStreams::Errors::MissingHeader` for a record before the columns of the rows are known, see #read_header.
      def row_parse(line)
        values = parse(line)
        return values unless @keyed && values.is_a?(::Hash)

        row_of(values)
      end

      # Returns [Hash] the record of the line, by the columns, see `IOStreams::Tabular::Header#to_hash`, or nil when it
      # is blank.
      def record_parse(line)
        values = parse(line)
        header.to_hash(values) if values
      end

      # Returns [String|Array|Hash] the line that the parser renders for the row or record: a record by the columns, see
      # `IOStreams::Tabular::Header#to_hash`, for a format of keyed records, such as JSON, otherwise its values in the
      # order of the columns, see `IOStreams::Tabular::Header#to_array`, see `IOStreams::Tabular::Parser::Base.keyed?`.
      # Returns nil for a row or record without values, `[]` or `{}`, which is written as a blank line, unless blank rows
      # are records, see `IOStreams::Tabular::Mapping#initialize`, when it is rendered by the columns as any other.
      def render(row)
        return if @blank_rows && IOStreams::Utils.blank?(row)

        # The columns of a format of keyed records, such as JSON, are known once the first row gives them, when the record
        # written has every one of them, otherwise its keys are its columns.
        record = @keyed && header.columns ? header.to_record(row) : row
        @parser.render(@keyed ? header.to_hash(record) : header.to_array(row))
      end

      # Returns [String] the header row of the columns, once the columns supplied to it, if any, become the columns, such
      # as the first row written.
      # Returns nil when the format has no header row, once a format of keyed records takes the columns supplied, such as
      # the first row written, which name the keys of the rows after it.
      #
      # Raises `IOStreams::Errors::MissingHeader` when the columns are not known, or the columns supplied to a format of
      # keyed records are empty.
      def render_header(columns = nil)
        header.columns = columns if columns
        return unless @requires_header || (@keyed && columns)

        if IOStreams::Utils.blank?(header.columns)
          raise(
            Errors::MissingHeader,
            "Header columns must be set before attempting to render a header for format: #{@format.inspect}"
          )
        end

        @parser.render(header.columns) if @requires_header
      end

      private

      # The plan of a record whose keys are the columns of the rows, in order, whose values are its row, see #row_plan.
      IN_ORDER = :in_order
      private_constant :IN_ORDER

      # Returns [Array<String>] the keys of the record of the line, or of the row of keys supplied, such as the header row
      # that the rows read start with, as they are, which become the columns of the rows, and of the records. Returns
      # nil when it is blank, see `IOStreams::Tabular::Mapping#parse`, such as a JSON line of `null` or `{}`, or a record
      # whose every value is null, which gives no columns.
      #
      # The columns of the rows are its own, and so is the header row returned, so that a caller that changes one does not
      # change the columns that the rows after it are read by.
      def parse_keys(line)
        values = parse(line)
        return if values.nil?

        header.columns = values.is_a?(::Hash) ? values.keys : values
        @keys          = header.columns.map { |key| key.frozen? ? key : key.dup.freeze }
        clear_row_plans
        @keys.map(&:dup)
      end

      # Returns [Array] the value of each column of the rows from a record, see #row_parse: for each of the keys of the
      # first record, see #parse_keys, the value of the key of its name, or nil when the record does not have it.
      #
      # Raises `IOStreams::Errors::MissingHeader` before the columns of the rows are known.
      # Raises `IOStreams::Errors::InvalidHeader` for a key that is not one of the keys of the first record, since a row
      # has no column for it.
      def row_of(record)
        unless @keys
          raise(Errors::MissingHeader, "The columns of the rows of the #{@format.inspect} format are the keys of its first " \
                                       "record, which must be read first, see IOStreams::Tabular#read_header")
        end

        keys = record.keys
        plan = keys.eql?(@row_keys) ? @row_plan : row_plan(keys)
        return record.values if plan.equal?(IN_ORDER)

        plan.map { |key| record[key] unless key.nil? }
      end

      # Returns [Array|Symbol] how the row of a record whose keys are the supplied keys is taken from it, see #row_of,
      # worked out once for each list of keys: IN_ORDER when its keys are the columns of the rows, in order, so that its
      # values are the row, otherwise the key of the record that holds each column, or nil when it has none. A key is
      # the column of its text, as a header row converts it, see `IOStreams::Tabular::Header#columns=`.
      #
      # Raises `IOStreams::Errors::InvalidHeader` for a key that is not a column, see #row_of.
      def row_plan(keys)
        @row_plan = @row_plans.fetch(keys) do
          texts   = keys.map { |key| key.is_a?(String) ? key : IOStreams::Schema::Field.any_text(key) }
          unknown = texts - @keys
          raise_unknown_keys(unknown) unless unknown.empty?

          @row_plans.clear if @row_plans.size >= Header::PLANS
          @row_plans[keys] =
            if texts == @keys
              IN_ORDER
            else
              # Of two keys with the same text, the last holds the value of their column, as for a header row.
              by_text = texts.zip(keys).to_h
              @keys.map { |column| by_text[column] }
            end
        end
        @row_keys = keys
        @row_plan
      end

      # Forgets the plans of the rows of the records read, see #row_plan, when the columns of the rows change.
      def clear_row_plans
        @row_plans = {}
        @row_keys  = nil
        @row_plan  = nil
      end

      # Raises `IOStreams::Errors::InvalidHeader` for the keys of a record that are not columns of the rows, see #row_of.
      def raise_unknown_keys(unknown)
        names = unknown.map(&:inspect)
        names = names.size <= 2 ? names.join(" and ") : "#{names[0..-2].join(', ')} and #{names.last}"
        which = unknown.size == 1 ? "the key #{names} is not one of them" : "the keys #{names} are not among them"
        raise(
          Errors::InvalidHeader,
          "The keys of a record do not match the columns of the rows, which are the keys of the first record: #{which}. " \
          "Read the records with each(:hash), or describe the columns with a schema whose fields are every key, with " \
          "fieldsMatch \"superset\" when a record can leave out a key"
        )
      end
    end
  end
end
