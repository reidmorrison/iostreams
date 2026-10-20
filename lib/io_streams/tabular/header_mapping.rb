# frozen_string_literal: true

module IOStreams
  class Tabular
    # Maps the columns of a file without a schema, see `IOStreams::Tabular::Mapping`, by its header: the columns of its
    # header row, or the columns supplied in place of one, which the records of a format of keyed records, such as JSON,
    # do not need, but its rows do: without them, the keys of its first record are the columns of its rows, which it
    # reads as their header row, see #read_header.
    #
    # Applies the column options of the header, `allowed_columns`, `required_columns` and `skip_unknown`, which are
    # deprecated, to every input when reading: the header row, the columns supplied, and the keys of each record of a
    # format without a header row. Unless `IOStreams.enforce_column_restrictions?`, they are only applied to a header row
    # that is cleansed, and otherwise a warning is logged, once, when applying them would change the result. They never
    # change a row, whose columns it holds apart from the columns of the records.
    class HeaderMapping < Mapping
      # Parameters:
      #   cleanse: [true|false]
      #     Whether to cleanse the header row read, see `IOStreams::Tabular::Header#cleanse!`, as the `cleanse_header`
      #     option of `IOStreams::Tabular.new` says, which #read_header, #restrict_columns and #read_record apply, unless
      #     #read_header is told otherwise.
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
        # The columns of the rows of a format whose rows they arrange, see #row_parse, apart from the columns of the
        # records, which the column options cleanse and restrict, see #restrict_columns, since they never change a row:
        # the columns supplied, as they are supplied, or the keys of the first record of a format of keyed records,
        # see #read_header, whose plans it keeps, see #row_plan.
        @rows            = Header.new(columns: header.columns) if @supplied
        @keys            = nil
        clear_row_plans
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

      # Returns [true|false] whether the rows read start with a header row, which names the column of each value of the
      # rows after it: the header row of a file with one, until it is read, see #header?, or for a format of keyed
      # records, such as JSON, the keys of its first record, until they are read, see #read_rows_header, unless the
      # columns were supplied.
      def rows_header?
        header? || (@keyed && @rows.nil? && @keys.nil?)
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

      # Returns [Array] the header row parsed from the line, which becomes the columns of the header, before it is
      # cleansed, see `IOStreams::Tabular#parse_header`. For a format of keyed records, such as JSON, the keys of the
      # record of the line, or of a row of keys, which become the columns of the rows, see #parse_keys.
      # Returns nil when the line is blank, or the format has no header row.
      def parse_header(line)
        return parse_keys(line) if @keyed
        return unless @requires_header

        columns = parse(line)
        return if columns.nil?

        header.columns = columns
        columns
      end

      # Parses the header row, see #parse_header, then cleanses its columns when `cleanse` is truthy, otherwise applies
      # the column restrictions to them as they are, see #restrict_columns. For a format without a header row, such as
      # the layout of a fixed width file, they apply to the columns supplied. The keys of a format of keyed records are
      # only cleansed when the columns are restricted, as its records are, see #read_record.
      #
      # Returns [Array] the header row as read, before it is cleansed, or nil when the line is blank, or the format does
      # not have a header row.
      def read_header(line, cleanse: @cleanse)
        columns = parse_header(line)
        if @keyed
          restrict_columns(rename: cleanse)
        else
          cleanse ? header.cleanse! : restrict_columns(rename: false)
        end
        columns
      end

      # Returns [Array] the header row of the rows, which is not a line of its own, see #rows_header?: the keys of the
      # record of the line of a format of keyed records, such as JSON, whose columns were not supplied, see #read_header,
      # or nil when the line is blank, such as a JSON line of `null`, which gives no keys.
      def read_rows_header(line)
        read_header(line)
      end

      # Applies the column restrictions to the columns once they are known, such as the columns supplied in place of a
      # header row, renaming them when `rename`, see `IOStreams::Tabular::Header#cleanse!`.
      def restrict_columns(rename: @cleanse)
        return if header? || !header.restricted?
        return header.cleanse!(rename: rename) if IOStreams.enforce_column_restrictions?

        warn_restriction("header row") if !@warned && header.cleanse_changes?(rename: rename)
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

      # Returns [Hash] the record of the line, see #record_parse, with the column restrictions applied to its keys for a
      # format without a header row, such as JSON, whose records each supply their own keys, renaming them when
      # `cleanse`, see #initialize and `IOStreams::Tabular::Header#restrict_hash`.
      # Returns nil if the line is blank.
      def read_record(line)
        record = record_parse(line)
        return record unless record.is_a?(::Hash) && header.restricted? && header.columns.nil?
        return header.restrict_hash(record, rename: @cleanse) if IOStreams.enforce_column_restrictions?

        # Once warned, the remaining records are not checked.
        warn_restriction("records") if !@warned && header.restrict_hash_changes?(record, rename: @cleanse)
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
        @rows          = nil
        clear_row_plans
        @keys.map(&:dup)
      end

      # Returns [Array] the value of each column of the rows from a record, see #row_parse: for the columns supplied, the
      # value of the key of its name, or of the first key that is the same once cleansed, skipping the other keys, as the
      # records read do, see `IOStreams::Tabular::Header#to_array`, otherwise, for the keys of the first record, see
      # #parse_keys, the value of the key of its name, or nil when the record does not have it.
      #
      # Raises `IOStreams::Errors::MissingHeader` before the columns of the rows are known.
      # Raises `IOStreams::Errors::InvalidHeader` for a key that is not one of the keys of the first record, since a row
      # has no column for it.
      def row_of(record)
        return @rows.to_array(record) if @rows

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
