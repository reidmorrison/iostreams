# frozen_string_literal: true

module IOStreams
  # Common handling for efficiently processing tabular data such as CSV, spreadsheet or other tabular files
  # on a line by line basis.
  #
  # Tabular consists of a table of data where the first row is usually the header, and subsequent
  # rows are the data elements.
  #
  # Tabular applies the header information to every row of data when #record_parse is called.
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
    autoload :HeaderMapping, "io_streams/tabular/header_mapping"
    autoload :LayoutMapping, "io_streams/tabular/layout_mapping"
    autoload :Mapping, "io_streams/tabular/mapping"
    autoload :SchemaMapping, "io_streams/tabular/schema_mapping"
    autoload :Settings, "io_streams/tabular/settings"

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

    attr_reader :format, :parser, :schema

    # Returns [IOStreams::Tabular::Mapping] the mapping of the columns of the file to the values of its rows and records,
    # by the header row or the columns supplied, by the fields of a schema, or by the layout of a fixed width file, which
    # is chosen when the Tabular is created, see #initialize.
    attr_reader :mapping

    # The default of the `cleanse_header` option, see #initialize, and of `cleanse:`, see #read_header, which cleanses
    # the header row without a schema. Distinct from nil, which does not cleanse it, as before.
    CLEANSE_BY_DEFAULT = :default

    # The options of #initialize that describe the format of the file, which reading and writing both accept. They are
    # set on the path, see `IOStreams::Tabular::Settings`, so that a call to read or write the rows cannot supply them,
    # see `IOStreams::Stream::PATH_SETTINGS`.
    FORMAT_OPTION_NAMES = %i[format file_name schema format_options default_format row_format_options].freeze

    # The options of #initialize that only apply when reading: whether to cleanse the header row read, see #read_header.
    READ_OPTION_NAMES = %i[cleanse_header].freeze

    # Returns [Array<Symbol>] the options of #initialize that a call to read rows or records supplies, see
    # `IOStreams::Row::Reader.option_names`: those that only apply when reading, and those of the header, see
    # `IOStreams::Tabular::Header`, but not those that describe the format of the file, see FORMAT_OPTION_NAMES.
    def self.read_option_names
      [*READ_OPTION_NAMES, *Header::OPTION_NAMES]
    end

    # Returns [Array<Symbol>] the options of #initialize that a call to write rows or records supplies, see
    # `IOStreams::Row::Writer.option_names`: those of the header, other than the restrictions of the columns read, see
    # `IOStreams::Tabular::Header::READ_OPTION_NAMES`.
    def self.write_option_names
      Header::OPTION_NAMES - Header::READ_OPTION_NAMES
    end

    # Returns [Array<Symbol>] the options of a call that reads or writes rows or records, see .read_option_names and
    # .write_option_names, that are deprecated, since a schema describes the columns of the file instead: whether to
    # cleanse the header row, and the options of the header, see `IOStreams::Tabular::Header`. A call still accepts them,
    # and reports a deprecation warning, see #initialize.
    def self.deprecated_option_names
      [*READ_OPTION_NAMES, *Header::OPTION_NAMES]
    end

    # Parse a delimited data source.
    #
    # Parameters
    #   format: [Symbol]
    #     A registered format, see .registered_formats: :csv, :hash, :array, :json, :psv, :fixed or :parquet
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
    #       When supplied, a column that it rejects is prefixed with `__rejected__`, see
    #       `IOStreams::Tabular::Header::IGNORE_PREFIX`, in the cleansed columns, so that it can be ignored during
    #       processing.
    #
    #   required_columns [Array<String>]
    #     Deprecated: see `constraints` in `IOStreams::Schema::Field`.
    #     List of columns that must be present, otherwise an Exception is raised.
    #
    #   skip_unknown [true|false]
    #     Deprecated: see `fieldsMatch` in `IOStreams::Schema`.
    #     true:
    #       Skip the columns that are not in `allowed_columns`, by prefixing them with `__rejected__`, so that the
    #       records read, see #record_parse, skip them entirely, as if they were not in the file at all.
    #     false:
    #       Raises IOStreams::Errors::InvalidHeader for a column that is not in `allowed_columns`.
    #
    #   default_format: [Symbol]
    #     When the format is not supplied, and the format cannot be inferred from the supplied file name
    #     then this default format will be used.
    #     Default: :csv
    #     Set to nil to force it to raise an exception when the format is undefined.
    #
    #   row_format_options: [Hash]
    #     The options of the format that reads and writes the rows of a format whose rows are not lines, see #read_rows,
    #     such as those set with `option(:parquet, compression: "zstd")`, see `IOStreams::Tabular::Settings`.
    #     Default: none
    #
    #   cleanse_header: [true|false|nil]
    #     Deprecated: a schema names the keys of the records read instead, see `schema:`.
    #     Like `columns`, `allowed_columns`, `required_columns` and `skip_unknown`, it reports a deprecation warning when
    #     it is supplied, see `IOStreams::Deprecation`, unless it is nil, which is not supplied, apart from
    #     `cleanse_header: nil`, which does not cleanse the header row.
    #     Whether to cleanse the header row read, see `IOStreams::Tabular::Header#cleanse!`, which #read_header,
    #     #read_record and #restrict_columns apply, unless #read_header is told otherwise. nil does not cleanse it, as
    #     before it was deprecated. With a schema it raises ArgumentError, including for nil, since it would have no effect.
    #     Default: CLEANSE_BY_DEFAULT, which cleanses it.
    def initialize(format: nil, file_name: nil, schema: nil, format_options: nil, default_format: :csv,
                   row_format_options: nil, cleanse_header: CLEANSE_BY_DEFAULT, **args)
      if schema
        reject_header_options(args)
        reject_header_cleansing(cleanse_header)
      end
      header  = Header.new(**args)
      @format = file_name && format.nil? ? self.class.format_from_file_name(file_name) : format
      @format ||= default_format
      raise(Errors::UnknownFormat, "The format cannot be inferred from the file name: #{file_name}") unless @format

      layout              = legacy_schema(format_options, schema)
      @schema             = layout || schema
      @row_format_options = row_format_options || {}
      @parser             = self.class.parser_class(@format).new(schema: @schema)
      @mapping            = build_mapping(header, schema, layout, cleanse_header ? true : false)
      warn_deprecated_options(args, cleanse_header)
    end

    # Returns [IOStreams::Tabular::Header] the columns of the file: the header row read, or the columns supplied in
    # place of one, and their restrictions, see `IOStreams::Tabular::Header`. With a schema, the header row as it was
    # read, see #read_header.
    def header
      @mapping.header
    end

    # Returns [true|false] whether a header is still required in order to parse or render the current format: until
    # the header row is read, for a format with one, unless the columns are already known.
    def header?
      @mapping.header?
    end

    # Returns [true|false] whether the rows read start with a header row, which names the column of each value of the
    # rows after it, see #read_row: the header row of a file with one, until it is read, see #header?, or for a format of
    # keyed records, such as JSON, without a schema or the columns supplied, the keys of its first record, until they are
    # read, since the columns of its rows are not known until then.
    def rows_header?
      @mapping.rows_header?
    end

    # Returns [Array<String|Symbol>] the columns of the rows that #row_parse returns of a file without a header row,
    # so that a copy can give them to the target, see `IOStreams::Row::Reader#copy_to`: the names of the fields of a
    # schema, see `IOStreams::Schema#header?`, such as of fixed width or JSON, or the keys of the layout of a fixed width
    # file, or the columns supplied for it.
    # Returns nil for any other file, such as one whose rows start with a header row, see #rows_header?.
    def headerless_columns
      @mapping.headerless_columns
    end

    # Returns [true|false] whether the keys of the records read are the names of the fields of a schema, rather than the
    # columns of the file, so that cleansing the header row does not apply, see `IOStreams::Schema::Columns`.
    def field_names?
      @mapping.field_names?
    end

    # Returns [true|false] whether a header row should be rendered on output: when the format has one, unless the
    # schema says that the file has none, see `IOStreams::Schema#header?`.
    def requires_header?
      @mapping.requires_header?
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
    # supplied stream of its bytes, in the form that #row_parse and #record_parse accept, by the format of the rows,
    # with the options of the rows supplied to #initialize, such as those set with `option(:parquet, ...)`.
    #
    # The reader is given the schema, as the writer is, see #write_rows, so that a reader that can read only some of the
    # columns of a file, such as Parquet, reads only those of its fields when the schema skips the others, see
    # `IOStreams::Parquet::Reader.file`.
    #
    # Returns the result of the block.
    def read_rows(io, &)
      parser.class.row_format.open_stream(:reader, io, @row_format_options, name: format, arguments: {schema: schema}, &)
    end

    # Yields [#<<] the writer of the rows of a format whose rows are not lines, see #lines?, to the supplied stream of
    # its bytes, which takes the rows that #render returns, with the options of the rows, see #read_rows. It writes the
    # fields of the schema, which give the type of each column.
    #
    # Returns the result of the block.
    def write_rows(io, &)
      parser.class.row_format.open_stream(:writer, io, @row_format_options, name: format, arguments: {schema: schema}, &)
    end

    # Raises what #write_rows would raise before it writes anything, such as for a schema whose fields the format cannot
    # write, or an option value that it does not accept, so that the caller can check before it opens the output, which
    # would replace an existing file, see `IOStreams::StreamFormat#check_stream`.
    def check_write_rows
      parser.class.row_format.check_stream(:writer, @row_format_options, name: format, arguments: {schema: schema})
    end

    # Returns [String] the encoding that the format reads and writes text in when the caller does not set one on
    # the encode stream, such as "US-ASCII:UTF-8" for fixed width files, or [nil] for the default encoding of the
    # encode stream, UTF-8.
    def encoding
      parser.class.encoding
    end

    # Returns [Array] the header row/line after parsing. Without a schema, for a format of keyed records, such as JSON,
    # the keys of the record of the line, or the row of keys supplied, which become the columns of its rows, see
    # #rows_header?.
    # Returns `nil` if the row/line is blank, or the format has no header row, such as fixed width, or JSON with a schema.
    #
    # Notes:
    # * Call `header?` first to determine if the header should be parsed first.
    # * The header columns are set after parsing the row, but the header is not cleansed.
    # * With a schema, its columns are matched to the fields, see `IOStreams::Schema::Columns#match`.
    def parse_header(line)
      @mapping.parse_header(line)
    end

    # Returns [Hash<String,Object>] the line as a hash, or a row already read, an Array, such as one that #read_row
    # yielded, by the columns of the rows, whatever the format, as Rocket Job's workers parse the rows uploaded.
    # With a schema, the keys are the names of the fields, and the values are converted to their types, see
    # `IOStreams::Schema::Columns`.
    # Returns nil if the line is blank.
    def record_parse(line)
      @mapping.record_parse(line)
    end

    # Returns [Array] the row/line as a parsed Array of values. With a schema, the values of its fields, in the order of
    # the fields, converted to their types, see `IOStreams::Schema::Columns`. For a format whose records supply their own
    # keys, such as JSON, the values of the record in the order of the columns of the rows: every field of a schema,
    # nil for a key that the record does not have, or without one, the keys of the first record, see #read_header.
    # Returns nil if the row/line is blank, or a record without keys, such as a JSON line of `{}`.
    #
    # Raises `IOStreams::Errors::TypeMismatch` when a line of JSON is not an object, since only a record has keys.
    # Raises `IOStreams::Errors::InvalidHeader` for a key of a record that is not a column of the rows, see #read_row.
    def row_parse(line)
      @mapping.row_parse(line)
    end

    # Renders the output row, once the mapping of the columns arranges it in the form of the rows of the format, see
    # `IOStreams::Tabular::Mapping`. With a schema, a record or row has the value of each field in the form of its field
    # that the format writes, see `IOStreams::Schema::Field#render`, and in the order of the fields, see
    # `IOStreams::Schema::Columns#render`.
    #
    # Returns nil for a blank row, which is written as a blank line, unless the schema has a field that is required,
    # which raises `IOStreams::Errors::InvalidValue`, since the row has no value for it.
    def render(row)
      @mapping.render(row)
    end

    # Returns [String] the header rendered for the output format
    # Return nil if no header is required.
    #
    # When columns are supplied they become the header columns first, such as the first row written
    # when the columns were not supplied. With a schema, the header row is the names of its fields, and the columns
    # supplied are matched to the fields instead, so that the value of each field is taken from its column of the rows
    # rendered after it, see `IOStreams::Schema::Columns#match_written`.
    def render_header(columns = nil)
      @mapping.render_header(columns)
    end

    # Returns [Array<String>] the cleansed columns
    def cleanse_header!
      header.cleanse!
      header.columns
    end

    # Reading applies `allowed_columns`, `required_columns` and `skip_unknown` to every input: a header row, supplied
    # columns, and the keys of each record of a format without a header row, such as JSON. Unless
    # `IOStreams.enforce_column_restrictions?`, they are only applied to a header row that is cleansed, and otherwise
    # a warning is logged, once, when applying them would change the result, see `IOStreams::Tabular::HeaderMapping`.

    # Parses the header row, then cleanses its columns when `cleanse:` is truthy, otherwise applies the column
    # restrictions to them as they are, see #restrict_columns. For a format without a header row, such as the layout of
    # a fixed width file, they apply to the columns supplied. `cleanse:` defaults to the `cleanse_header` option, see
    # #initialize, which cleanses them unless it is false or nil.
    #
    # With a schema, matches its columns to the fields instead, see `IOStreams::Schema::Columns#match`, so `cleanse:`
    # cannot be supplied. The header columns are the header row as it was read, so that another Tabular with the same
    # schema, such as one that reads the rest of the file elsewhere, matches the same columns with
    # `read_header(header.columns)`.
    #
    # Without a schema, the header row of a format of keyed records, such as JSON, is the keys of the record of the line,
    # or the row of keys supplied, such as the header row that #read_row yielded, as they are, which are only cleansed
    # when the columns are restricted, as its records are.
    #
    # Returns [Array] the header row as read, before it is cleansed, or with a schema, the names of the fields of its
    # columns, in the order of the fields.
    # Returns nil when the line is blank, or the format does not have a header row.
    def read_header(line, **)
      @mapping.read_header(line, **)
    end

    # Applies the column restrictions to the header columns once they are known, such as the columns supplied in
    # place of a header row, renaming them as the `cleanse_header` option says, see #initialize and
    # `IOStreams::Tabular::Header#cleanse!`. With a schema no column options apply.
    def restrict_columns
      @mapping.restrict_columns
    end

    # Returns [Hash<String,Object>] the line as a record, with the column restrictions applied to its keys for a
    # format without a header row, such as JSON, whose records each supply their own keys, renaming them as the
    # `cleanse_header` option says, see #initialize and `IOStreams::Tabular::Header#restrict_hash`. With a schema the
    # keys are the names of the fields.
    # Returns nil if the line is blank.
    def read_record(line)
      @mapping.read_record(line)
    end

    # Reading and writing a line at a time: a reader or writer of rows or records, see `IOStreams::Row::Reader` and the
    # others, hands each line or value to these, which decide whether it is the header row, as the mapping of the
    # columns answers, see `IOStreams::Tabular::Mapping`, so that the reader or writer only iterates.

    # Yields [Array|nil] each row of the line of a file of rows: the header row, while it is expected, see #header?,
    # which it reads, see #read_header, otherwise the row, see #row_parse, or nil for a blank line. The first record of a
    # format of keyed records whose columns are not known, see #rows_header?, such as JSON without a schema, yields its
    # keys as the header row before its row, since they name the column of each value of the rows.
    #
    # Returns the result of the block.
    def read_row(line)
      # Once the header row is read, every line is a row, so that is asked first.
      return yield(@mapping.row_parse(line)) unless @mapping.rows_header?
      return yield(@mapping.read_header(line)) if @mapping.header?

      columns = @mapping.read_header(line)
      yield columns if columns
      yield @mapping.row_parse(line)
    end

    # Yields [Hash|nil] the record of the line of a file of records, see #read_record, or nil for a blank line, unless
    # the line is the header row, while it is expected, see #header?, which it reads instead, see #read_header, since it
    # names the keys of the records after it.
    def read_record_line(line)
      if @mapping.header?
        @mapping.read_header(line)
      else
        yield @mapping.read_record(line)
      end
    end

    # Yields [String] the header line that a writer of rows writes before the first row: the columns supplied, when the
    # format has a header row, see #requires_header?, otherwise nothing, since the first row written is the header row,
    # see #render_row.
    def start_rows
      yield render_header if @mapping.requires_header? && !@mapping.first_row_header?
    end

    # Yields [String|nil] the line that a writer of rows writes for the row: the header line, when it is the header row,
    # see `IOStreams::Tabular::Mapping#first_row_header?`, whose columns it gives, otherwise the line of the row, see
    # #render, or nil for a blank row, which is written as a blank line. The header row of a format without one, such
    # as JSON, gives the columns of the rows after it, but no line, see #render_header.
    #
    # Returns the result of the block.
    def render_row(row)
      return yield(@mapping.render(row)) unless @mapping.first_row_header?

      line = @mapping.render_header(row)
      yield line unless line.nil?
    end

    # Yields [String|nil] the line that a writer of rows writes for the header row of the rows after it, which were read
    # from a file with one, such as the file that is copied, see `IOStreams::Row::Reader#copy_to`: as the first row, see
    # #render_row, unless the header row gives the columns of the rows instead, for a format without a header row, such
    # as JSON or Parquet, see `IOStreams::Tabular::Mapping#columns_from_header_row?`, when it yields nothing.
    def render_header_row(columns, &)
      return render_row(columns, &) unless @mapping.columns_from_header_row?

      render_header(columns)
      nil
    end

    # Yields [String|nil] the line that a writer of rows writes for the columns of the rows after it, which are not a row
    # of the file that they are read from, such as the fields of a file without a header row, see
    # `IOStreams::Row::Reader#copy_to`: as their header row, see #render_header_row, unless the columns were supplied,
    # which name them instead, when it yields nothing.
    def render_columns(columns, &)
      render_header_row(columns, &) unless @mapping.columns_supplied?
    end

    # Yields [String] the header line that a writer of rows writes once the rows have been written, when it wrote none:
    # the names of the fields of a schema, of a file with a header row, when no row was written, since the first row
    # gives the columns of the rows, see #render_row. Without a schema the first row is the header row, so there is none
    # to write without it.
    def finish_rows
      return unless @mapping.requires_header? && @mapping.first_row_header?

      yield render_header unless @mapping.columns_from_first_row?
    end

    # Yields [String] the header line that a writer of records writes before the first record: the names of the fields
    # of a schema, or the columns supplied, when the format has a header row, see #requires_header?, otherwise nothing,
    # including when the keys of the first record give the columns, see #render_record.
    def start_records
      yield render_header if @mapping.requires_header? && !@mapping.columns_from_first_row?
    end

    # Yields [String|nil] each line that a writer of records writes for the record: the header line first, once, when
    # the keys of the first record give the columns, since neither a schema nor the columns supplied give them, then the
    # line of the record, see #render, or nil for a blank record, which is written as a blank line.
    def render_record(record)
      yield @mapping.render_header(record.keys) if @mapping.columns_from_first_row?
      yield @mapping.render(record)
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

    # Raises ArgumentError for `cleanse_header:` with a schema, whose fields name the keys of the records read instead,
    # see #field_names?, including nil, which does not cleanse the header row, since it would have no effect.
    def reject_header_cleansing(cleanse_header)
      return if cleanse_header.equal?(CLEANSE_BY_DEFAULT)

      raise(ArgumentError, "cleanse_header: cannot be supplied with a schema, since the keys of its records are the " \
                           "names of its fields, which the columns of the header row are matched to, see " \
                           "IOStreams::Schema#field_for")
    end

    # Reports a deprecation warning, see `IOStreams::Deprecation`, for the options of the header that are supplied, which
    # are not nil, and `cleanse_header:`, including nil, which does not cleanse the header row, since a schema describes
    # the columns of the file instead, and names the keys of the records read.
    def warn_deprecated_options(args, cleanse_header)
      names = args.compact.keys & Header::OPTION_NAMES
      names << :cleanse_header unless cleanse_header.equal?(CLEANSE_BY_DEFAULT)
      return if names.empty?

      Deprecation.warn("#{names.map { |name| "#{name}:" }.join(', ')} #{names.size == 1 ? 'is' : 'are'} deprecated, " \
                       "describe the columns of the file with #schema instead")
    end

    # Returns [IOStreams::Tabular::Mapping] the mapping of the columns of the file, see #mapping: by the fields of the
    # schema supplied, by the layout supplied as format options, which are deprecated, see #legacy_schema, whose records
    # the options of the header still apply to, as before it was deprecated, otherwise by the header, which applies the
    # options of the header, and cleanses the header row read when `cleanse`.
    def build_mapping(header, schema, layout, cleanse)
      if schema
        SchemaMapping.new(schema, header: header, parser: parser, format: format)
      elsif layout
        LayoutMapping.new(layout, header: header, parser: parser, format: format, cleanse: cleanse)
      else
        HeaderMapping.new(header: header, parser: parser, format: format, cleanse: cleanse)
      end
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
  end
end
