module IOStreams
  class Tabular
    # Maps the columns of a file without a schema, see `IOStreams::Tabular::Mapping`, by its header: the columns of its
    # header row, or the columns supplied in place of one, and the column options, `allowed_columns`,
    # `required_columns` and `skip_unknown`, see `IOStreams::Tabular::Header`.
    #
    # It reads and writes the rows and records as IOStreams 2.1 does, whose readers and writers of rows and records
    # held the code of its reading and writing methods, see `IOStreams::Row::Reader` and the others, so that a file
    # without a schema is read and written as before.
    class HeaderMapping < Mapping
      # See `IOStreams::Tabular::Mapping#initialize`.
      def initialize(header:, parser:, format:)
        super
        # Whether the columns were supplied, which a writer writes as the header row before the first row or record,
        # see #start_rows.
        @supplied = !header.columns.nil?
        # Whether a reader of records has logged that the column restrictions would change what it reads, which it
        # logs once, see #warn_restriction.
        @warned   = false
      end

      # Returns [true|false] whether a header is still required in order to parse or render the current format.
      def header?
        @parser.requires_header? && IOStreams::Utils.blank?(header.columns)
      end

      # Returns [true|false] whether a header row show be rendered on output.
      def requires_header?
        @parser.requires_header?
      end

      # Returns [true|false] whether the rows read start with a header row: the header row of a file with one, until it
      # is read, see #header?.
      def rows_header?
        header?
      end

      # Returns [nil] only the fields of a schema are the columns of a file without a header row, see
      # `IOStreams::Tabular#headerless_columns`.
      def headerless_columns
        nil
      end

      # Returns [Array] the header row/line after parsing and cleansing.
      # Returns `nil` if the row/line is blank, or a header is not required for the supplied format (:json, :hash).
      #
      # Notes:
      # * Call `header?` first to determine if the header should be parsed first.
      # * The header columns are set after parsing the row, but the header is not cleansed.
      def parse_header(line)
        return if IOStreams::Utils.blank?(line) || !@parser.requires_header?

        header.columns = @parser.parse(line)
      end

      # Parses the header row, see #parse_header, then cleanses its columns when `cleanse`, otherwise applies the column
      # restrictions to them, as a reader of records reads its header row, see #read_record_line.
      #
      # Returns [Array] the header row as read, before it is cleansed, or nil when the line is blank, or the format does
      # not have a header row.
      def read_header(line, cleanse: CLEANSE_BY_DEFAULT)
        cleanse = cleanse?(cleanse)
        columns = parse_header(line)
        if cleanse
          cleanse_columns(cleanse)
        elsif restricted?
          restrict_header(cleanse)
        end
        columns
      end

      # Returns [Array] the row/line as a parsed Array of values.
      # Returns nil if the row/line is blank.
      def row_parse(line)
        return if IOStreams::Utils.blank?(line)

        @parser.parse(line)
      end

      # Returns [Hash<String,Object>] the line as a hash.
      # Returns nil if the line is blank.
      def record_parse(line)
        line = row_parse(line)
        header.to_hash(line) if line
      end

      # Renders the output row
      def render(row)
        return if IOStreams::Utils.blank?(row)

        @parser.render(row, header)
      end

      # Returns [String] the header rendered for the output format
      # Return nil if no header is required.
      def render_header
        return unless requires_header?

        if IOStreams::Utils.blank?(header.columns)
          raise(
            Errors::MissingHeader,
            "Header columns must be set before attempting to render a header for format: #{@format.inspect}"
          )
        end

        @parser.render(header.columns, header)
      end

      # Yields [Array] each row of the line of a file of rows: the header row, while it is expected, see #header?, once
      # it is cleansed when `cleanse`, otherwise the row, see #row_parse, or nil for a blank line.
      def read_row(line, cleanse: CLEANSE_BY_DEFAULT)
        if header?
          columns = parse_header(line)
          header.cleanse! if cleanse?(cleanse)
          yield columns
        else
          yield row_parse(line)
        end
      end

      # Yields [Hash] the record of the line of a file of records, see #record_parse, or nil for a blank line, unless the
      # line is the header row, while it is expected, see #header?, which it reads instead, see #read_header. The column
      # restrictions are applied to the keys of each record of a format without a header row, such as JSON, when
      # `IOStreams.enforce_column_restrictions?`, see #restrict.
      def read_record_line(line, cleanse: CLEANSE_BY_DEFAULT)
        if header?
          read_header(line, cleanse: cleanse)
          nil
        else
          yield restrict(record_parse(line), cleanse?(cleanse))
        end
      end

      # Applies the column restrictions to the columns supplied, which take the place of a header row, as a reader of
      # records does before it reads the file, see `IOStreams::Record::Reader#initialize`.
      def restrict_columns(cleanse: CLEANSE_BY_DEFAULT)
        restrict_header(cleanse?(cleanse)) if restricted? && !header?
      end

      # Yields [String] the header line of the columns supplied, which a writer of rows or records writes before the
      # first row or record, see `IOStreams::Row::Writer#initialize`, when the format has a header row.
      def start_rows
        yield render_header if @supplied && requires_header?
      end

      alias start_records start_rows

      # Yields [String|nil] the line that a writer of rows writes for the row: the header line, when the columns are not
      # known yet, whose columns it gives, otherwise the line of the row, see #render, or nil for a blank row.
      #
      # Returns the result of the block.
      def render_row(row)
        if header?
          # If header (columns) was not supplied as an argument, assume first line is the header.
          header.columns = row
          yield render_header
        else
          yield render(row)
        end
      end

      # Yields [String|nil] each line that a writer of records writes for the record: the header line first, once, of
      # the keys of the first record, when the columns are not known yet, then the line of the record, see #render.
      #
      # Returns the result of the block.
      def render_record(record)
        if header?
          # Extract header from the keys from the first row when not supplied above.
          header.columns = record.keys
          yield render_header
        end
        yield render(record)
      end

      # Yields [String|nil] the line that a writer of rows writes for the header row of the rows after it, such as an
      # `IOStreams::Row::HeaderRow` that `IOStreams::Stream#each(:array)` yields with a schema: as the first row, see
      # #render_row, unless the format has no header row, such as JSON, and the columns are not known, when it takes
      # them as the columns of the rows after it, without a line.
      #
      # Raises `IOStreams::Errors::MissingHeader` when the columns that it takes are empty.
      def render_header_row(columns, &)
        return render_row(columns, &) if requires_header? || !header.columns.nil?

        if IOStreams::Utils.blank?(columns)
          raise(Errors::MissingHeader, "The header row of the rows written to the #{@format.inspect} format has no columns")
        end

        header.columns = columns
        nil
      end

      # Yields [String|nil] the line that a writer of rows writes for the columns of the rows after it, which are not a
      # row of the file that they are read from, such as the fields of a file without a header row, see
      # `IOStreams::Row::Reader#copy_to`: as their header row, see #render_header_row, unless the columns were supplied,
      # which name them instead, when it yields nothing.
      def render_columns(columns, &)
        render_header_row(columns, &) unless @supplied
      end

      private

      # Returns [true|false] whether to cleanse the header row read, the `cleanse_header` option of the reader:
      # true for `IOStreams::Tabular::CLEANSE_BY_DEFAULT`, the default.
      def cleanse?(cleanse)
        cleanse.equal?(CLEANSE_BY_DEFAULT) || cleanse
      end

      def restricted?
        header.restricted?
      end

      def cleanse_columns(cleanse)
        header.cleanse!(rename: cleanse)
      end

      # Apply the allowed and required columns to supplied columns, or to a header row read with
      # `cleanse_header: false`. Unless `IOStreams.enforce_column_restrictions?`, only warn when they would
      # change the columns.
      def restrict_header(cleanse)
        return cleanse_columns(cleanse) if IOStreams.enforce_column_restrictions?
        return if @warned

        columns = header.columns
        changed = changed_by_restriction? do
          copy = IOStreams::Tabular::Header.new(
            columns:          columns,
            allowed_columns:  header.allowed_columns,
            required_columns: header.required_columns,
            skip_unknown:     header.skip_unknown
          )
          copy.cleanse!(rename: cleanse)
          copy.columns != columns
        end
        warn_restriction if changed
      end

      # Formats such as JSON have no header row, so apply the allowed and required columns to each record's keys.
      # Unless `IOStreams.enforce_column_restrictions?`, only warn when they would change the record.
      def restrict(record, cleanse)
        return record unless record.is_a?(Hash) && restricted? && header.columns.nil?
        return header.restrict_hash(record, rename: cleanse) if IOStreams.enforce_column_restrictions?
        return record if @warned

        warn_restriction if changed_by_restriction? { header.restrict_hash(record, rename: cleanse) != record }
        record
      end

      def changed_by_restriction?
        yield
      rescue IOStreams::Errors::InvalidHeader
        true
      end

      # Warn once per reader, since the same columns usually apply to every record.
      def warn_restriction
        @warned = true
        IOStreams.logger&.warn(
          "allowed_columns and required_columns are not applied to this input, but would change the records read. " \
          "In v3.0 they will apply to every input. Set `IOStreams.enforce_column_restrictions = true` to apply them now."
        )
      end
    end
  end
end
