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
    # The column options of a file without a schema do not apply, since the schema describes the columns, see
    # `IOStreams::Tabular.new`. The header keeps the header row as it was read, so that another Tabular with the same
    # schema, such as one that reads the rest of the file elsewhere, matches the same columns with
    # `read_header(header.columns)`.
    #
    # Its text is UTF-8, as IOStreams 3.0 reads and writes the text of every file by default: a line read as binary,
    # as a file is read without an encoding, see `IOStreams::Stream#option`, is taken as UTF-8, unless the text was
    # decoded by an encoding set on the stream, and so is binary text written, such as the values of rows read from a
    # file without a schema, see #utf8.
    class SchemaMapping < Mapping
      # Parameters:
      #   schema: [IOStreams::Schema]
      #     The fields of the rows and records.
      #
      #   decoded: [true|false]
      #     Whether the text of the lines read was decoded by an encoding set on the stream, so that it is taken as it
      #     is, rather than a binary line as UTF-8, see #utf8.
      #     Default: false
      #
      #   See `IOStreams::Tabular::Mapping#initialize` for the others.
      #
      # Raises ArgumentError when the schema describes a file without a header row, of a format with one, such as CSV,
      # that it cannot describe, see `IOStreams::Schema#check_fields_in_order`.
      def initialize(schema, header:, parser:, format:, decoded: false)
        super(header: header, parser: parser, format: format)
        @schema          = schema
        @decoded         = decoded
        @columns         = schema.columns
        @requires_header = parser.requires_header? && schema.header?
        # Whether each row is a record whose keys are its columns, such as JSON, rather than the values in the order of
        # the columns, see `IOStreams::Tabular::Parser::Base.keyed?`, and the form in which the format writes the values
        # of the fields.
        @keyed           = parser.class.keyed?
        @form            = parser.class.value_form
        # The parsers render a row by a header, see `IOStreams::Tabular::Header#to_array`, which leaves a row whose
        # values the schema has already arranged as it is, since it has no columns.
        @arranged        = Header.new.freeze
        # The columns of the rows of a file without a header row are the fields, in order: of a format with one whose
        # schema says that it has none, see `IOStreams::Schema#check_fields_in_order`, or of a format without one, such
        # as fixed width, or JSON, whose rows are the values of the fields of its records.
        if parser.requires_header?
          @columns.match_fields unless schema.header?
        else
          @columns.match_in_order
        end
        # Whether the names of the fields have been read as the header row of the rows of a file without one, see
        # #rows_header?.
        @names_read = false
      end

      # Returns [true|false] whether the file has a header row: when its format has one, such as CSV, unless the schema
      # says that the file has none, see `IOStreams::Schema#header?`.
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
      # fields, which are the columns of its rows, until they are read, see #read_row, so that the rows of every file
      # start with a header row.
      def rows_header?
        @requires_header ? header? : !@names_read
      end

      # Returns [Array<String|Symbol>] the names of the fields of a file without a header row, which are the columns of
      # its rows, see `IOStreams::Tabular#headerless_columns`.
      # Returns nil for a file with a header row.
      def headerless_columns
        @columns.names if @columns.matched? && !@requires_header
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
      #
      # Raises ArgumentError for `cleanse`, other than nil or `IOStreams::Tabular::CLEANSE_BY_DEFAULT`, which leave the
      # header row as it is, since the keys of the records are the names of the fields, which its columns are matched to
      # instead.
      def read_header(line, cleanse: CLEANSE_BY_DEFAULT)
        reject_cleanse(cleanse, "cleanse") unless cleanse.nil?

        match_header(line)&.last
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
      # Returns nil for a blank row, which is written as a blank line, unless the schema has a field that is required,
      # which raises `IOStreams::Errors::InvalidValue`, since the row has no value for it.
      def render(row)
        return @columns.render_blank if IOStreams::Utils.blank?(row)

        @parser.render(@columns.render(utf8_row(row), @form, @keyed), @arranged)
      end

      # Returns [String] the header row of the file: the names of its fields.
      # Returns nil when the file has no header row.
      def render_header
        return unless @requires_header

        @parser.render(@schema.fields.map { |field| field.name.to_s }, @arranged)
      end

      # Yields [Array|nil] each row of the line of a file of rows: the header row, while it is expected, see #header?,
      # as the names of the fields of its columns, see #read_header, otherwise the row, see #row_parse, or nil for a
      # blank line. The rows of a file without a header row, such as fixed width, JSON, or a schema whose `header` is
      # false, start with the names of the fields, before the row of the first line, since they are the columns of its
      # rows.
      #
      # The header row is an `IOStreams::Row::HeaderRow`, so that a writer of rows takes it as the header row of the
      # rows after it, see `IOStreams::Row::Writer#<<`.
      #
      # Raises ArgumentError for `cleanse`, the `cleanse_header` option of the reader, other than the default, see
      # #read_header.
      #
      # Returns the result of the block.
      def read_row(line, cleanse: CLEANSE_BY_DEFAULT)
        reject_cleanse(cleanse)
        # Once the header row is read, every line is a row, so that is asked first.
        return yield(row_parse(line)) unless rows_header?
        return yield(as_header_row(read_header(line))) if header?

        @names_read = true
        yield as_header_row(@columns.names)
        yield row_parse(line)
      end

      # Yields [Hash|nil] the record of the line of a file of records, see #record_parse, or nil for a blank line, unless
      # the line is the header row, while it is expected, see #header?, which it reads instead, see #read_header, since
      # it names the keys of the records after it.
      #
      # Raises ArgumentError for `cleanse` other than the default, see #read_row.
      def read_record_line(line, cleanse: CLEANSE_BY_DEFAULT)
        reject_cleanse(cleanse)
        if header?
          read_header(line)
          nil
        else
          yield record_parse(line)
        end
      end

      # Returns nil: no column options apply, since the schema describes the columns instead.
      #
      # Raises ArgumentError for `cleanse` other than the default, see #read_row.
      def restrict_columns(cleanse: CLEANSE_BY_DEFAULT)
        reject_cleanse(cleanse)
        nil
      end

      # Yields [String] the header line that a writer of rows or records writes before the first one, the names of the
      # fields, when the file has a header row, see #requires_header?, so that every row written is the values of the
      # fields, in order, as for a file without a header row.
      def start_rows
        yield render_header if @requires_header
      end

      alias start_records start_rows

      # Yields [String|nil] the line of the row, see #render.
      #
      # Returns the result of the block.
      def render_row(row)
        yield render(row)
      end

      alias render_record render_row

      # Takes the columns of the rows written after them from a header row written before them, such as the
      # `IOStreams::Row::HeaderRow` that `IOStreams::Stream#each(:array)` yields, or the header row of a file without a
      # schema that is copied, see `IOStreams::Row::Reader#copy_to`, once they are matched to the fields, see
      # `IOStreams::Schema::Columns#match_written`, without a line, since the header row of the file is the names of the
      # fields, which the schema writes, see #start_rows, or the file has none.
      #
      # Returns nil.
      def render_header_row(columns)
        @columns.match_written(utf8_row(columns))
        nil
      end

      alias render_columns render_header_row

      private

      # Returns [Array(Array, Array)] the header row parsed from the line, which the header keeps as it was read, and the
      # names of the fields of its columns, once they are matched to the fields, or nil when the line is blank, or the
      # format has no header row.
      def match_header(line)
        return unless @requires_header

        columns = parse(line.is_a?(::Array) ? utf8_row(line) : line)
        return if columns.nil?

        names          = @columns.match(columns)
        header.columns = columns
        [columns, names]
      end

      # Returns [Array|Hash] the values of the line, which the parser parses, or a row already read, an Array, as it is,
      # since the parsers of keyed records, such as JSON, do not accept one without a schema.
      #
      # Returns nil when it is blank, the same way in every format: a line that is blank, see
      # `IOStreams::Utils.blank_text?`, or a row or record whose every value is blank, see `IOStreams::Utils.blank_row?`,
      # such as a line of CSV of only commas, or a JSON record of `null`, `{}`, or whose every value is null.
      def parse(line)
        return if line.nil?

        if line.is_a?(String)
          line = utf8(line) unless @decoded
          return if IOStreams::Utils.blank_text?(line)
        end

        values = line.is_a?(::Array) ? line : @parser.parse(line)
        values unless IOStreams::Utils.blank_row?(values)
      end

      # Returns [String] the text, taken as UTF-8 when it is binary, as IOStreams 2 reads a file without an encoding,
      # see `IOStreams::Stream#option`, so that its values are UTF-8 strings, and their labels can be matched to the
      # names of the fields, which compares the letters of every language only in Unicode, see
      # `IOStreams::Schema.match_key`.
      #
      # Raises `IOStreams::Errors::InvalidEncoding` when it is not valid UTF-8.
      def utf8(text)
        return text unless text.encoding == ::Encoding::BINARY

        utf8 = text.dup.force_encoding(::Encoding::UTF_8)
        return utf8 if utf8.valid_encoding?

        invalid = utf8.each_char.find { |char| !char.valid_encoding? }.b
        raise(
          IOStreams::Errors::InvalidEncoding.new(
            "#{invalid.inspect} is not valid UTF-8. Set the encoding of the file with option(:encode, encoding: ...)",
            error_char:           invalid,
            source_encoding:      ::Encoding::BINARY,
            destination_encoding: ::Encoding::UTF_8
          )
        )
      end

      # Returns [Array|Hash] the row or record, whose text that is binary and not ASCII is taken as UTF-8, see #utf8,
      # such as that of a row read from a file without a schema, which is binary, or the row itself when it has none.
      def utf8_row(row)
        case row
        when ::Array
          row.any? { |value| binary_text?(value) } ? row.map { |value| utf8_text(value) } : row
        when ::Hash
          return row unless row.any? { |key, value| binary_text?(key) || binary_text?(value) }

          row.to_h { |key, value| [utf8_text(key), utf8_text(value)] }
        else
          row
        end
      end

      def utf8_text(value)
        binary_text?(value) ? utf8(value) : value
      end

      def binary_text?(value)
        value.is_a?(String) && value.encoding == ::Encoding::BINARY && !value.ascii_only?
      end

      # Returns [IOStreams::Row::HeaderRow] the columns of a header row that #read_row yields, or nil when there are none,
      # such as for a blank line.
      def as_header_row(columns)
        IOStreams::Row::HeaderRow.new(columns) if columns
      end

      # Raises ArgumentError for the `cleanse_header` option of a reader, other than the default, since the keys of the
      # records are the names of the fields, which the columns of the header row are matched to instead.
      def reject_cleanse(cleanse, name = "cleanse_header")
        return if cleanse.equal?(CLEANSE_BY_DEFAULT)

        raise(ArgumentError, "#{name}: cannot be supplied with a schema, since the keys of its records are the " \
                             "names of its fields, which the columns of the header row are matched to, see " \
                             "IOStreams::Schema#field_for")
      end
    end
  end
end
