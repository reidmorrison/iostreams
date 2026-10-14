# frozen_string_literal: true

module IOStreams
  # Common handling for efficiently processing tabular data such as CSV, spreadsheet or other tabular files
  # on a line by line basis.
  #
  # Tabular consists of a table of data where the first row is usually the header, and subsequent
  # rows are the data elements.
  #
  # Tabular applies the header information to every row of data when #as_hash is called.
  #
  # Example using the default CSV parser:
  #
  #   tabular = Tabular.new
  #   tabular.parse_header("first field,Second,thirD")
  #   # => ["first field", "Second", "thirD"]
  #
  #   tabular.cleanse_header!
  #   # => ["first_field", "second", "third"]
  #
  #   tabular.record_parse("1,2,3")
  #   # => {"first_field"=>"1", "second"=>"2", "third"=>"3"}
  #
  #   tabular.record_parse([1,2,3])
  #   # => {"first_field"=>1, "second"=>2, "third"=>3}
  #
  #   tabular.render([5,6,9])
  #   # => "5,6,9"
  #
  #   tabular.render({"third"=>"3", "first_field"=>"1" })
  #   # => "1,,3"
  class Tabular
    autoload :Header, "io_streams/tabular/header"

    module Parser
      autoload :Array, "io_streams/tabular/parser/array"
      autoload :Base, "io_streams/tabular/parser/base"
      autoload :Csv, "io_streams/tabular/parser/csv"
      autoload :Fixed, "io_streams/tabular/parser/fixed"
      autoload :Hash, "io_streams/tabular/parser/hash"
      autoload :Json, "io_streams/tabular/parser/json"
      autoload :Parquet, "io_streams/tabular/parser/parquet"
      autoload :Psv, "io_streams/tabular/parser/psv"
    end

    attr_reader :format, :header, :parser, :schema

    # The default of the `cleanse_header` option of a reader, and of `cleanse:`, which cleanses the header row without a
    # schema, see #header_cleansing. Distinct from nil, which does not cleanse it, as before.
    CLEANSE_BY_DEFAULT = :default

    # The options of #initialize that describe the format of the file, which reading and writing both accept.
    FORMAT_OPTION_NAMES = %i[format file_name schema format_options default_format].freeze

    # Returns [Array<Symbol>] the options of a Tabular that reads rows or records, see #initialize: those of the format
    # of the file, and those of its header, see `IOStreams::Tabular::Header`.
    def self.read_option_names
      [*FORMAT_OPTION_NAMES, *Header::OPTION_NAMES]
    end

    # Returns [Array<Symbol>] the options of a Tabular that writes rows or records: all but the restrictions of the
    # columns read, see `IOStreams::Tabular::Header::READ_OPTION_NAMES`.
    def self.write_option_names
      [*FORMAT_OPTION_NAMES, *(Header::OPTION_NAMES - Header::READ_OPTION_NAMES)]
    end

    # Parse a delimited data source.
    #
    # Parameters
    #   format: [Symbol]
    #     :csv, :hash, :array, :json, :psv, :fixed
    #
    #   file_name: [IOStreams::Path | String]
    #     When `:format` is not supplied the file name can be used to infer the required format.
    #     Optional. Default: nil
    #
    #   schema: [IOStreams::Schema]
    #     The fields of the file, whose names are the keys of each record read, and the type of each one, which converts
    #     the values of each row read, and renders those written, see `IOStreams::Stream#schema`. The columns of the
    #     file are matched to the fields, see `IOStreams::Schema::Columns`. A fixed width file needs it for the position
    #     of each field.
    #     Since the schema describes the columns of the file, the options below that describe them without one,
    #     `columns`, `allowed_columns` and `required_columns`, raise ArgumentError with it, unless they are nil.
    #     `skip_unknown` only applies to `allowed_columns`, so it does not.
    #     Optional. Default: nil
    #
    #   format_options: [Hash]
    #     Deprecated, use `schema:`. The layout and truncate option of a fixed width file, which are translated into
    #     the schema, see `IOStreams::Tabular::Parser::Fixed.schema`, so it raises ArgumentError for any other format.
    #     The options below still apply to its records, as they did before it was deprecated.
    #
    #   columns [Array<String|Symbol>]
    #     Deprecated: the fields of a schema are the columns, see `schema:`.
    #     The header columns when the file does not include a header row.
    #     Note:
    #       Column names are converted to strings.
    #
    #   allowed_columns [Array<String>]
    #     Deprecated: see `fieldsMatch` in `IOStreams::Schema`.
    #     List of columns to allow.
    #     Default: nil ( Allow all columns )
    #     Note:
    #       When supplied any columns that are rejected will be returned in the cleansed columns
    #       as nil so that they can be ignored during processing.
    #
    #   required_columns [Array<String>]
    #     Deprecated: see `constraints` in `IOStreams::Schema::Field`.
    #     List of columns that must be present, otherwise an Exception is raised.
    #
    #   skip_unknown [true|false]
    #     Deprecated: see `fieldsMatch` in `IOStreams::Schema`.
    #     true:
    #       Skip columns not present in the `allowed_columns` by cleansing them to nil.
    #       #as_hash will skip these additional columns entirely as if they were not in the file at all.
    #     false:
    #       Raises Tabular::InvalidHeader when a column is supplied that is not in the whitelist.
    #
    #   default_format: [Symbol]
    #     When the format is not supplied, and the format cannot be inferred from the supplied file name
    #     then this default format will be used.
    #     Default: :csv
    #     Set to nil to force it to raise an exception when the format is undefined.
    def initialize(format: nil, file_name: nil, schema: nil, format_options: nil, default_format: :csv, **args)
      reject_header_options(args) if schema
      @header = Header.new(**args)
      @format = file_name && format.nil? ? self.class.format_from_file_name(file_name) : format
      @format ||= default_format
      raise(Errors::UnknownFormat, "The format cannot be inferred from the file name: #{file_name}") unless @format

      @schema      = legacy_schema(format_options, schema) || schema
      @field_names = !schema.nil?
      @parser      = self.class.parser_class(@format).new(schema: @schema)
      @columns     = @schema&.columns
      # A Header without columns, through which the parsers render the rows that the schema has already arranged.
      @plain_header = Header.new if @columns
      @warned       = false
      # The columns of a file without a header row are the fields, in order.
      @columns.match_fields if @columns && parser.requires_header? && !@schema.header?
    end

    # Returns [true|false] whether a header is still required in order to parse or render the current format: until
    # the header row is read, for a format with one, unless the columns are already known.
    def header?
      return requires_header? && !@columns.matched? if @columns

      parser.requires_header? && IOStreams::Utils.blank?(header.columns)
    end

    # Returns [true|false] whether a writer takes the columns of the file from the first row or record written, since
    # neither a schema nor the supplied columns give them.
    def columns_from_first_row?
      @columns ? false : header?
    end

    # Returns [true|false] whether the next row written is a header row, which names the column of each value of the
    # rows after it, see `IOStreams::Row::Writer`: without a schema, when the columns are not known yet, see
    # #columns_from_first_row?, and with one, for a file with a header row, see #requires_header?, until it is written,
    # so that the rows read from a file with a header row, which start with it, can be written, see
    # `IOStreams::Schema::Columns#match_written`.
    def first_row_header?
      return columns_from_first_row? unless field_names?

      requires_header? && !@columns.written?
    end

    # Returns [true|false] whether the header row of the rows written after it, such as the one read from the file that
    # is copied, see `IOStreams::Row::Writer#write_header`, gives their columns, see #render_header, rather than being
    # written as the first row: for a format without a header row, such as JSON or Parquet, unless the columns were
    # supplied, which it does not replace, so that it is written as a row, as before.
    def columns_from_header_row?
      !(first_row_header? || requires_header? || legacy_columns?)
    end

    # Returns [true|false] whether the keys of the records read are the names of the fields of a schema, rather than the
    # columns of the file, so that cleansing the header row does not apply, see `IOStreams::Schema::Columns`.
    def field_names?
      @field_names
    end

    # Returns [true|false|nil] whether a reader cleanses the header row, see `IOStreams::Tabular::Header#cleanse!`, for
    # its `cleanse_header` option, which is deprecated: true when it is not supplied, otherwise whether it is truthy, or
    # nil with a schema, whose fields name the keys of each record instead, see #field_names?.
    #
    # Raises ArgumentError when the option is supplied with a schema, since it would have no effect.
    def header_cleansing(cleanse_header)
      default = cleanse_header.equal?(CLEANSE_BY_DEFAULT)
      return default || (cleanse_header ? true : false) unless field_names?
      return if default

      raise(ArgumentError, "cleanse_header: cannot be supplied with a schema, since the keys of its records are the " \
                           "names of its fields, which the columns of the header row are matched to, see " \
                           "IOStreams::Schema#field_for")
    end

    # Returns [true|false] whether a header row show be rendered on output: when the format has one, unless the
    # schema says that the file has none, see `IOStreams::Schema#header?`.
    def requires_header?
      parser.requires_header? && (schema.nil? || schema.header?)
    end

    # Returns [String] the quote character within which the format embeds field delimiters and newlines,
    # such as `"` for CSV, or [nil] when the format has no such quoting.
    #
    # So that the lines of the data are split where this format, which parses them, expects.
    def quote_character
      parser.class.quote_character
    end

    # Returns [true|false] whether the rows of the format are lines of text, which a line reader splits and a line writer
    # writes, rather than a binary layout of its own, such as Parquet, see #read_rows.
    def lines?
      parser.class.row_format.nil?
    end

    # Yields [#each] the rows of the binary layout of a format whose rows are not lines, see #lines?, read from the
    # supplied stream of its bytes, in the form that #row_parse and #record_parse accept.
    #
    # With a schema whose `fieldsMatch` skips the columns that it does not list, a reader that can read only some of the
    # columns of a file, such as Parquet, reads only those of its fields, see `IOStreams::Schema#projection`.
    #
    # Parameters:
    #   options: [Hash]
    #     The options of the format, set with `IOStreams::Stream#option`, such as `option(:parquet, ...)`.
    #
    # Returns the result of the block.
    def read_rows(io, options)
      parser.class.row_format.open_stream(:reader, io, options, name: format) do |rows|
        read_only_fields(rows)
        yield(rows)
      end
    end

    # Yields [#<<] the writer of the rows of a format whose rows are not lines, see #lines?, to the supplied stream of
    # its bytes, which takes the rows that #render returns. It writes the fields of the schema, which give the type of
    # each column.
    #
    # Parameters:
    #   options: [Hash]
    #     The options of the format, see #read_rows.
    #
    # Returns the result of the block.
    def write_rows(io, options, &)
      parser.class.row_format.open_stream(:writer, io, options, name: format, arguments: {schema: schema}, &)
    end

    # Raises what #write_rows would raise before it writes anything, such as for a schema whose fields the format cannot
    # write, or an option value that it does not accept, so that the caller can check before it opens the output, which
    # would replace an existing file, see `IOStreams::StreamFormat#check_stream`. See #read_rows for the options.
    def check_write_rows(options)
      parser.class.row_format.check_stream(:writer, options, name: format, arguments: {schema: schema})
    end

    # Returns [String] the encoding that the format reads and writes text in when the caller does not set one on
    # the encode stream, such as "US-ASCII:UTF-8" for fixed width files, or [nil] for the default encoding of the
    # encode stream, UTF-8.
    def encoding
      parser.class.encoding
    end

    # Returns [Array] the header row/line after parsing.
    # Returns `nil` if the row/line is blank, or a header is not required for the supplied format (:json, :hash).
    #
    # Notes:
    # * Call `header?` first to determine if the header should be parsed first.
    # * The header columns are set after parsing the row, but the header is not cleansed.
    # * With a schema, its columns are matched to the fields, see `IOStreams::Schema::Columns#match`.
    def parse_header(line)
      return if IOStreams::Utils.blank?(line) || !parser.requires_header?

      columns = parser.parse(line)
      @columns.match(columns) if field_names?
      header.columns = columns
    end

    # Returns [Hash<String,Object>] the line as a hash.
    # With a schema, the keys are the names of the fields, and the values are converted to their types, see
    # `IOStreams::Schema::Columns`.
    # Returns nil if the line is blank.
    def record_parse(line)
      return parse_record(line) if @columns

      line = row_parse(line)
      header.to_hash(line) if line
    end

    # Returns [Array] the row/line as a parsed Array of values. With a schema, the values of its fields, in the order of
    # the fields, converted to their types, or the record of a format whose records supply their own keys, such as
    # JSON, see `IOStreams::Schema::Columns`.
    # Returns nil if the row/line is blank.
    def row_parse(line)
      row = parse_values(line)
      return row if row.nil? || !@columns

      row.is_a?(::Hash) ? @columns.read_hash(row) : @columns.row(row)
    end

    # Renders the output row. With a schema, a record or row has the value of each field in the form of its field that
    # the format writes, see `IOStreams::Schema::Field#render`, and in the order of the fields, see
    # `IOStreams::Schema::Columns#render`.
    #
    # Returns nil for a blank row, which is written as a blank line, unless the schema has a field that is required,
    # which raises `IOStreams::Errors::InvalidValue`, since the row has no value for it.
    def render(row)
      unless @columns
        return if IOStreams::Utils.blank?(row)

        return parser.render(row, header)
      end
      return @columns.render_blank if IOStreams::Utils.blank?(row)

      row = header.to_hash(row) if legacy_columns?
      parser.render(@columns.render(row, parser.class.value_form, !parser.requires_header?), @plain_header)
    end

    # Returns [String] the header rendered for the output format
    # Return nil if no header is required.
    #
    # When columns are supplied they become the header columns first, such as the first row written
    # when the columns were not supplied. With a schema, the header row is the names of its fields, and the columns
    # supplied are matched to the fields instead, so that the value of each field is taken from its column of the rows
    # rendered after it, see `IOStreams::Schema::Columns#match_written`.
    def render_header(columns = nil)
      return render_field_names(columns) if @columns

      header.columns = columns if columns
      return unless requires_header?

      if IOStreams::Utils.blank?(header.columns)
        raise(
          Errors::MissingHeader,
          "Header columns must be set before attempting to render a header for format: #{format.inspect}"
        )
      end

      parser.render(header.columns, header)
    end

    # Returns [Array<String>] the cleansed columns
    def cleanse_header!
      header.cleanse!
      header.columns
    end

    # Reading applies `allowed_columns`, `required_columns` and `skip_unknown` to every input: a header row, supplied
    # columns, and the keys of each record of a format without a header row, such as JSON. Unless
    # `IOStreams.enforce_column_restrictions?`, they are only applied to a header row that is cleansed, and otherwise
    # a warning is logged, once, when applying them would change the result.

    # Parses the header row, then cleanses its columns when `cleanse` is not supplied, or is truthy, otherwise applies the
    # column restrictions to them as they are, see #restrict_columns. For a format without a header row, such as the
    # layout of a fixed width file, they apply to the columns supplied.
    #
    # With a schema, matches its columns to the fields instead, see `IOStreams::Schema::Columns#match`, so `cleanse`
    # cannot be supplied. The header columns are the header row as it was read, so that another Tabular with the same
    # schema, such as one that reads the rest of the file elsewhere, matches the same columns with
    # `read_header(header.columns)`.
    #
    # Returns [Array] the header row as read, before it is cleansed, or with a schema, the names of the fields of its
    # columns, in the order of the fields.
    # Returns nil when the line is blank, or the format does not have a header row.
    def read_header(line, cleanse: CLEANSE_BY_DEFAULT)
      return match_header(line, cleanse) if field_names?

      columns = parse_header(line)
      cleanse ? header.cleanse! : restrict_columns(rename: false)
      columns
    end

    # Applies the column restrictions to the header columns once they are known, such as the columns supplied in
    # place of a header row, renaming them when `rename`, see `IOStreams::Tabular::Header#cleanse!`.
    def restrict_columns(rename: true)
      return if header? || !header.restricted?
      return header.cleanse!(rename: rename) if IOStreams.enforce_column_restrictions?

      warn_restriction("header row") if !@warned && header.cleanse_changes?(rename: rename)
    end

    # Returns [Hash<String,Object>] the line as a record, with the column restrictions applied to its keys for a
    # format without a header row, such as JSON, whose records each supply their own keys, renaming them when
    # `rename`, see `IOStreams::Tabular::Header#restrict_hash`.
    # Returns nil if the line is blank.
    def read_record(line, rename: true)
      record = record_parse(line)
      return record unless record.is_a?(Hash) && header.restricted? && header.columns.nil?
      return header.restrict_hash(record, rename: rename) if IOStreams.enforce_column_restrictions?

      # Once warned, the remaining records are not checked.
      warn_restriction("records") if !@warned && header.restrict_hash_changes?(record, rename: rename)
      record
    end

    # Register a format and the parser class for it.
    #
    # Example:
    #   register_format(:csv, IOStreams::Tabular::Parser::Csv)
    def self.register_format(format, parser)
      raise(ArgumentError, "Invalid format #{format.inspect}") unless format.to_s =~ /\A\w+\Z/

      @formats[format.to_sym] = parser
    end

    # De-Register a file format
    #
    # Returns [Symbol] the format removed, or nil if the format was not registered
    #
    # Example:
    #   deregister_format(:psv)
    def self.deregister_format(format)
      raise(ArgumentError, "Invalid format #{format.inspect}") unless format.to_s =~ /\A\w+\Z/

      @formats.delete(format.to_sym)
    end

    # Returns [Array<Symbol>] the list of registered formats
    def self.registered_formats
      @formats.keys
    end

    # A registry to hold formats for processing files during upload or download
    @formats = {}

    # Returns the registered format that will be used for the supplied file name.
    def self.format_from_file_name(file_name)
      Utils.file_name_extensions(file_name).reverse_each { |ext| return ext.to_sym if @formats.include?(ext.to_sym) }
      nil
    end

    # Returns the parser class for the registered format.
    def self.parser_class(format)
      @formats[format&.to_sym] ||
        raise(ArgumentError, "Unknown Tabular Format: #{format.inspect}")
    end

    # Returns [String] the quote character of the registered format, see #quote_character,
    # or [nil] when the format has no such quoting, or when the format is nil.
    def self.quote_character(format)
      parser_class(format).quote_character unless format.nil?
    end

    # Returns [true|false] whether the rows of the registered format are lines of text, see #lines?, which they are when
    # the format is nil.
    def self.lines?(format)
      format.nil? || parser_class(format).row_format.nil?
    end

    # Returns [Module|nil] the format whose reader and writer read and write the rows of the registered format of the
    # supplied name, when its rows are not lines, see `IOStreams::Tabular::Parser::Base.row_format`, such as
    # `IOStreams::Parquet` for `:parquet`, otherwise nil, including when no format has that name.
    def self.row_format(format)
      @formats[format.to_sym]&.row_format if format.respond_to?(:to_sym)
    end

    # Returns [String] the encoding of the registered format, see #encoding,
    # or [nil] for the default encoding of the encode stream, or when the format is nil.
    def self.encoding(format)
      parser_class(format).encoding unless format.nil?
    end

    register_format(:array, IOStreams::Tabular::Parser::Array)
    register_format(:csv, IOStreams::Tabular::Parser::Csv)
    register_format(:fixed, IOStreams::Tabular::Parser::Fixed)
    register_format(:hash, IOStreams::Tabular::Parser::Hash)
    register_format(:json, IOStreams::Tabular::Parser::Json)
    register_format(:parquet, IOStreams::Tabular::Parser::Parquet)
    register_format(:psv, IOStreams::Tabular::Parser::Psv)

    private

    # Reads only the columns of the fields of the schema, when the reader of the rows can, see #read_rows.
    def read_only_fields(rows)
      return unless schema && rows.respond_to?(:read_only)

      labels = schema.projection { rows.labels }
      rows.read_only(labels) if labels
    end

    # Raises ArgumentError for the options of the header, such as `columns:` and `allowed_columns:`, which describe the
    # columns of a file without a schema, since the schema describes them, see `IOStreams::Schema`, rather than apply one
    # and ignore the other. An option that is nil is not supplied, and an option of the header that does not describe
    # the columns on its own is accepted, see `IOStreams::Tabular::Header.column_option_names`, so that a caller, such
    # as Rocket Job, can supply its options whether or not there is a schema.
    def reject_header_options(args)
      names = Header.column_option_names(args)
      return if names.empty?

      raise(
        ArgumentError,
        "#{names.map { |name| "#{name}:" }.join(', ')} cannot be supplied with a schema, which describes the columns " \
        "of the file: its fields are the columns, `fieldsMatch` says which other columns the file can have, and " \
        "`constraints: {required: true}` which fields it must have, see IOStreams::Schema"
      )
    end

    # Returns [IOStreams::Schema] the schema of the fixed width layout supplied as format options, which are deprecated,
    # or nil when there are none.
    #
    # Raises ArgumentError for a format other than fixed width, which a layout does not describe, as before it was
    # deprecated, when its parser raised for the options that it did not take.
    def legacy_schema(format_options, schema)
      return if format_options.nil? || format_options.empty?
      raise(ArgumentError, "Supply either schema: or format_options:, not both") if schema
      unless @format.to_s == "fixed"
        raise(ArgumentError, "format_options: is the layout of a fixed width file, so it only applies to the :fixed " \
                             "format, not #{@format.inspect}. Set the format with #format, or use a schema, see " \
                             "IOStreams::Stream#schema")
      end

      IOStreams::Schema.new(Parser::Fixed.schema(**format_options))
    end

    # Returns [true|false] whether the columns supplied apply to the records, as they do to those of the layout of a
    # fixed width file supplied as format options, which are deprecated, see #legacy_schema.
    def legacy_columns?
      !field_names? && !header.columns.nil?
    end

    # Returns [Array|Hash] the values of the line, see #row_parse, or nil when it is blank.
    #
    # Raises `IOStreams::Errors::TypeMismatch` with a schema when a line of a format whose records supply their own keys,
    # such as JSON, is not a record, since the schema cannot tell which field each of its values is.
    def parse_values(line)
      return if IOStreams::Utils.blank?(line)

      values = parser.parse(line)
      return values if values.nil? || values.is_a?(::Hash) || !@columns || parser.requires_header?

      raise(IOStreams::Errors::TypeMismatch, "With a schema, each line of the #{format.inspect} format must be a record, " \
                                             "whose keys are its columns, rather than #{values.class.name}")
    end

    # Returns [Hash] the record of the line, by the names of its fields, see #record_parse, or nil when it is blank.
    def parse_record(line)
      values = parse_values(line)
      return if values.nil?

      record = values.is_a?(::Hash) ? @columns.read_hash(values) : @columns.record(values)
      legacy_columns? ? header.to_hash(record) : record
    end

    # Returns [Array] the names of the fields of the columns of the header row, see #read_header.
    def match_header(line, cleanse)
      # A reader supplies nil, which #header_cleansing returns with a schema.
      unless cleanse.nil? || cleanse.equal?(CLEANSE_BY_DEFAULT)
        raise(ArgumentError, "cleanse: cannot be supplied with a schema, since the keys of its records are the names of " \
                             "its fields, which the columns of the header row are matched to")
      end
      return if IOStreams::Utils.blank?(line) || !parser.requires_header?

      columns = parser.parse(line)
      names   = @columns.match(columns)
      header.columns = columns
      names
    end

    # Returns [String] the header row of a file with a schema: the names of its fields, see #render_header, once the
    # columns supplied, if any, are matched to the fields.
    def render_field_names(columns)
      @columns.match_written(columns) if columns
      return unless requires_header?

      parser.render(schema.fields.map { |field| field.name.to_s }, @plain_header)
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
