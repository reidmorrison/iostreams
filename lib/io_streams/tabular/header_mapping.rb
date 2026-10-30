# frozen_string_literal: true

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
      class << self
        # Sets whether the column restrictions, the `allowed_columns`, `required_columns` and `skip_unknown` options of
        # the header, apply to every input: also to the columns supplied, to a header row read with
        # `cleanse_header: false`, and to the keys of each record of a format without a header row, such as JSON, see
        # #restrict_header and #restrict, rather than only to a header row that is read and cleansed. Each mapping reads
        # it once, when it is created, see #initialize.
        #
        # The application sets it with `IOStreams.enforce_column_restrictions=`, which is deprecated, and reports a
        # deprecation warning. The mapping, which applies the setting, holds it, so that IOStreams reads it without one.
        attr_writer :enforce_column_restrictions

        # Returns [true|false] whether the column restrictions apply to every input, see .enforce_column_restrictions=.
        def enforce_column_restrictions?
          @enforce_column_restrictions
        end
      end

      @enforce_column_restrictions = false

      # Parameters:
      #   cleanse: [true|false]
      #     Whether to cleanse the header row read, see `IOStreams::Tabular::Header#cleanse!`, as the `cleanse_header`
      #     option of `IOStreams::Tabular.new` says, which #read_header, #read_row, #read_record_line and
      #     #restrict_columns apply, unless #read_header is told otherwise.
      #     Default: true
      #
      #   See `IOStreams::Tabular::Mapping#initialize` for the others.
      def initialize(header:, parser:, format:, cleanse: true)
        super(header: header, parser: parser, format: format)
        @cleanse  = cleanse
        # Whether the columns were supplied, which a writer writes as the header row before the first row or record,
        # see #start_rows.
        @supplied = !header.columns.nil?
        # Whether a reader of records has logged that the column restrictions would change what it reads, which it
        # logs once, see #warn_restriction.
        @warned   = false
        # Whether the column restrictions apply to every input, read once, rather than for each record, see
        # .enforce_column_restrictions?.
        @enforced = HeaderMapping.enforce_column_restrictions?
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

      # Returns [true|false] whether the rows read are the records of the file, see `IOStreams::Tabular#record_rows?`:
      # those of a format without a header row, such as JSON, whose parser reads each line into a record, keyed by the
      # names of its values, see #read_row.
      def record_rows?
        !@parser.requires_header?
      end

      # Returns [nil] only the fields of a schema are the columns of a file without a header row, see
      # `IOStreams::Tabular#headerless_columns`.
      def headerless_columns
        nil
      end

      # Returns [Array] the header row/line after parsing.
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
      # restrictions to them, as a reader of records reads its header row, see #read_record_line. `cleanse` defaults to
      # whether to cleanse the header row read, see #initialize.
      #
      # Returns [Array] the header row as read, before it is cleansed, or nil when the line is blank, or the format does
      # not have a header row.
      def read_header(line, cleanse: @cleanse)
        columns = parse_header(line)
        if cleanse
          header.cleanse!(rename: cleanse)
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

      # Yields [Array] each row of the line of a file of rows: the header row as it was parsed, see #parse_header, while
      # it is expected, see #header?, otherwise the row, see #row_parse, or nil for a blank line. The header columns are
      # then cleansed, when the header row read is cleansed, see #initialize, but the header row yielded is left as it is.
      def read_row(line)
        if header?
          columns = parse_header(line)
          header.cleanse! if @cleanse
          yield columns
        else
          yield row_parse(line)
        end
      end

      # Yields [Hash] the record of the line of a file of records, see #record_parse, or nil for a blank line, unless the
      # line is the header row, while it is expected, see #header?, which it reads instead, see #read_header. The column
      # restrictions are applied to the keys of each record of a format without a header row, such as JSON, when they
      # are enforced, see .enforce_column_restrictions? and #restrict.
      def read_record_line(line)
        if header?
          read_header(line)
          nil
        else
          yield restrict(record_parse(line))
        end
      end

      # Applies the column restrictions to the columns supplied, which take the place of a header row, as a reader of
      # records does before it reads the file, see `IOStreams::Record::Reader#initialize`, renaming them when the header
      # row read is cleansed, see #initialize.
      def restrict_columns
        restrict_header(@cleanse) if restricted? && !header?
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
      # `IOStreams::Row::HeaderRow` that `IOStreams::Stream#each(:array)` yields with a schema, or that a copy hands it,
      # see `IOStreams::Tabular#copy_row`: as the first row, see #render_row, unless the format has no header row, such
      # as JSON, and the columns are not known, when it takes them as the columns of the rows after it, without a line.
      # Yields nothing when the columns were supplied, which name the values of the rows instead.
      #
      # Raises `IOStreams::Errors::MissingHeader` when the columns that it takes are empty.
      # Raises `IOStreams::Errors::InvalidHeader` for a format without a header row whose rows are not records, see
      # `IOStreams::Tabular::Parser::Base.keyed?`, such as fixed width, whose layout gives its columns by their keys,
      # which the columns of a header row are not matched to, rather than write blank values. IOStreams 2.1 wrote it
      # as a row, which raised it too.
      def render_header_row(columns, &)
        return if @supplied
        return render_row(columns, &) if requires_header? || !header.columns.nil?

        unless @parser.class.keyed?
          raise(Errors::InvalidHeader, "The header row of the rows written to the #{@format.inspect} format cannot give " \
                                       "its columns, which its layout gives by their keys. Describe the columns of the " \
                                       "file with #schema instead, whose fields the columns of the header row are " \
                                       "matched to")
        end
        if IOStreams::Utils.blank?(columns)
          raise(Errors::MissingHeader, "The header row of the rows written to the #{@format.inspect} format has no columns")
        end

        header.columns = columns
        nil
      end

      # Returns [Array<String>] the header columns once they are cleansed, see `IOStreams::Tabular::Header#cleanse!`.
      def cleanse_header!
        header.cleanse!
        header.columns
      end

      # Yields nothing: only the fields of a schema are the columns of a file without a header row, see
      # `IOStreams::Tabular#start_copy`.
      def start_copy
        nil
      end

      # Yields [Array|nil] each row of the line that a copy writes, see `IOStreams::Tabular#copy_row`: as #read_row yields
      # it, but the header row as an `IOStreams::Row::HeaderRow`, which #read_row yields as an Array, as IOStreams 2.1
      # does.
      #
      # Returns the result of the block.
      def copy_row(line, &)
        return read_row(line, &) unless header?

        read_row(line) { |columns| yield(columns && IOStreams::Row::HeaderRow.new(columns)) }
      end

      private

      def restricted?
        header.restricted?
      end

      # Apply the allowed and required columns to supplied columns, or to a header row read with
      # `cleanse_header: false`, renaming them when `cleanse`. Unless they are enforced, see
      # .enforce_column_restrictions?, only warn when they would change the columns.
      def restrict_header(cleanse)
        return header.cleanse!(rename: cleanse) if @enforced
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

      # Formats such as JSON have no header row, so apply the allowed and required columns to each record's keys,
      # renaming them when the header row read is cleansed, see #initialize. Unless they are enforced, see
      # .enforce_column_restrictions?, only warn when they would change the record.
      def restrict(record)
        return record unless record.is_a?(Hash) && restricted? && header.columns.nil?
        return header.restrict_hash(record, rename: @cleanse) if @enforced
        return record if @warned

        warn_restriction if changed_by_restriction? { header.restrict_hash(record, rename: @cleanse) != record }
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
          "They are deprecated: describe the columns with #schema instead, which applies to every input."
        )
      end
    end
  end
end
