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
      autoload :Lines, "io_streams/tabular/parser/lines"
      autoload :Parquet, "io_streams/tabular/parser/parquet"
      autoload :Psv, "io_streams/tabular/parser/psv"
    end

    attr_reader :format, :parser, :schema

    # Returns [IOStreams::Tabular::Mapping] the mapping of the columns of the file to the values of its rows and records,
    # by the header row, or by the fields of a schema, which is chosen when the Tabular is created, see #initialize.
    attr_reader :mapping

    # The options of #initialize that describe the format of the file, which reading and writing both accept. They are
    # set on the path, see `IOStreams::Tabular::Settings`, so that a call to read or write the rows cannot supply them,
    # see `IOStreams::Stream::PATH_SETTINGS`.
    FORMAT_OPTION_NAMES = %i[format file_name schema default_format row_format_options].freeze

    # The options of #initialize that the stream of a source of rows that is not a file supplies, rather than the path
    # or a call: whether a row whose every value is blank is a blank row, which the rows of a database query are not, see
    # `IOStreams::Query::Stream`, nor the rows of a slice of them, which carries it, see `IOStreams::Slice::Stream`, and
    # whether the rows have no header row, which a slice says, see `IOStreams::Slice#header?`.
    SOURCE_OPTION_NAMES = %i[blank_rows headerless typed].freeze

    # Parse a delimited data source.
    #
    # Parameters
    #   format: [Symbol]
    #     A registered format, see .registered_formats: :csv, :hash, :array, :json, :lines, :psv, :fixed or :parquet
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
    #     Without a schema, the header row names the columns, which are cleansed, see `IOStreams::Tabular::Header#cleanse!`,
    #     and name the keys of each record read, and the first row or record written gives the columns written.
    #     Optional. Default: nil
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
    #   blank_rows: [true|false]
    #     Whether a row whose every value is blank, such as a line of CSV of only commas, is a blank row, read as nil, see
    #     `IOStreams::Tabular::Mapping`. False for rows that are each a record whatever their values, such as the rows of
    #     a database query, see `IOStreams::Query::Stream`, and of a slice that says so, see `IOStreams::Slice::Stream`.
    #     Not an option of a call that reads or writes rows.
    #     Default: true
    #
    #   headerless: [true|false|nil]
    #     Whether the rows have no header row, for a format that has one, such as CSV, whatever the schema says of the
    #     file, see `IOStreams::Schema#header?`: true or false for the rows of a slice, which says whether it carries
    #     one, see `IOStreams::Slice::Stream`, so that none of its rows is read as the header row. With a schema, the
    #     columns of rows without one are its fields in order. Without one, nothing names them, see #unnamed_columns?.
    #     Not an option of a call that reads or writes rows.
    #     Default: nil, as the schema says, otherwise as the format says, such as for a file.
    #
    #   typed: [true|false]
    #     Whether the values of the rows read are already those of the fields of the schema, as a schema rendered them,
    #     such as the rows of a slice that says so, see `IOStreams::Slice#typed?`, so that the schema matches their
    #     columns or keys to its fields, but does not convert their values again. Without a schema, no value is
    #     converted anyway.
    #     Not an option of a call that reads or writes rows.
    #     Default: false
    #
    # Raises ArgumentError for a `headerless` that is not true, false or nil, or a `typed` that is not true or false.
    def initialize(format: nil, file_name: nil, schema: nil, default_format: :csv, row_format_options: nil,
                   blank_rows: true, headerless: nil, typed: false)
      @format = file_name && format.nil? ? self.class.format_from_file_name(file_name) : format
      @format ||= default_format
      raise(Errors::UnknownFormat, "The format cannot be inferred from the file name: #{file_name}") unless @format
      unless [nil, true, false].include?(headerless)
        raise(ArgumentError, "headerless must be true, false or nil: #{headerless.inspect}")
      end
      raise(ArgumentError, "typed must be true or false: #{typed.inspect}") unless [true, false].include?(typed)

      @schema             = schema
      @typed              = typed
      @row_format_options = row_format_options || {}
      @parser             = self.class.parser_class(@format).new(schema: @schema)
      @mapping            = build_mapping(blank_rows, headerless, typed)
    end

    # Returns [IOStreams::Tabular] a new tabular with the same schema that reads the rows of the supplied format, such as
    # those of a slice that a writer of slices writes in the format of this one, see `IOStreams::Slice::Writer`: whether
    # they have no header row, whether a row whose every value is blank is a blank row, and whether their values are
    # already those of the fields, are as the slice says, see `IOStreams::Slice#header?`, `IOStreams::Slice#blank_rows?`
    # and `IOStreams::Slice#typed?`, whatever the schema says of the file, see
    # `headerless:` of #initialize. Without a schema, nothing names the columns of rows that have no header row, see
    # #unnamed_columns?, so the writer checks that this tabular can write them, see #check_unnamed_rows.
    def for_format(format, headerless:, blank_rows: true, typed: false)
      self.class.new(format: format, schema: @schema, blank_rows: blank_rows, headerless: headerless, typed: typed)
    end

    # Returns [IOStreams::Tabular::Header] the columns of the file: the header row read, or the keys of the first record,
    # see `IOStreams::Tabular::Header`. With a schema, the header row as it was read, see #read_header.
    def header
      @mapping.header
    end

    # Returns [true|false] whether a header is still required in order to parse or render the current format: until
    # the header row is read, for a format with one, unless the columns are already known.
    def header?
      @mapping.header?
    end

    # Returns [true|false] whether the rows read start with a header row, which names the column of each value of the
    # rows after it, see #read_row, until it is read: the header row of a file with one, see #header?, otherwise the
    # columns of the rows of a file without one, which are not a line of their own, see
    # `IOStreams::Tabular::Mapping#read_rows_header`: the names of the fields of a schema, such as of fixed width, of
    # JSON or Parquet, or of a file whose schema has `header: false`, or for a format of keyed records, such as JSON,
    # without a schema, the keys of its first record, since the columns of its rows are not known until then.
    def rows_header?
      @mapping.rows_header?
    end

    # Returns [Array<String|Symbol>] the columns of the rows that #row_parse returns of a file without a header row, which
    # #read_row yields as their header row, see #rows_header?, so that a copy can give them to the target, see
    # `IOStreams::Row::Reader#copy_to`: the names of the fields of a schema, see `IOStreams::Schema#header?`, such as of
    # fixed width or JSON.
    # Returns nil for any other file, such as one whose rows start with a header row of its own, see #rows_header?.
    def headerless_columns
      @mapping.headerless_columns
    end

    # Returns [Array<String>] the header row of the file as it was read, see #read_header, before it was cleansed or
    # matched to the fields of a schema, which the header keeps, see `IOStreams::Tabular::Header#row`, so that another
    # Tabular with the same format and schema, such as one that parses a slice of the file elsewhere, see
    # `IOStreams::Slice`, reads the rest of the file by the same columns with `read_header(header_row)`. It is frozen.
    # Returns nil until it is read, or when the file has no header row, see #requires_header?, such as fixed width, JSON,
    # or a schema whose `header` is false.
    def header_row
      header.row if requires_header?
    end

    # Returns [true|false] whether a row whose every value is blank is a blank row, read as nil, as in a file, see
    # `IOStreams::Tabular::Mapping`, rather than a record, as each row of a database query is, see `blank_rows:` of
    # #initialize, so that a slice of the rows carries it, see `IOStreams::Slice#blank_rows?`, and its rows are read the
    # same way where the slice is parsed.
    def blank_rows?
      @mapping.blank_rows?
    end

    # Returns [true|false] whether the values of the rows read are already those of the fields of the schema, see
    # `typed:` of #initialize, so that a slice of the rows carries it, see `IOStreams::Slice#typed?`, and its rows are
    # not converted again where the slice is read.
    def typed?
      @typed
    end

    # Returns [true|false] whether the rows that this format renders hold the values of the fields themselves, such as
    # Integers, Dates and Durations, rather than text, such as those of the `:hash` and `:array` formats, see
    # `IOStreams::Tabular::Parser::Base.value_form`, so that a store of the rows rendered knows that they are typed, see
    # `IOStreams::Slice::TargetStream`.
    def renders_values?
      parser.class.value_form == :typed
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

    # Parses the line, or a row already read, as a reader of its records would, see #record_parse, so that a value that
    # is not valid raises, for `validate: true`, see `IOStreams::Slice::Collector` and `IOStreams::Slice::Writer`: as a
    # row instead, see #row_parse, when nothing names the keys of its records, see #unnamed_columns?, such as the lines of
    # the :lines format without a schema, which have no records, but are rows.
    #
    # Returns nil.
    def validate_line(line)
      unnamed_columns? ? @mapping.row_parse(line) : @mapping.record_parse(line)
      nil
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
    # When columns are supplied they become the header columns first, such as the first row written. With a schema, the
    # header row is the names of its fields, and the columns supplied are matched to the fields instead, so that the value
    # of each field is taken from its column of the rows rendered after it, see `IOStreams::Schema::Columns#match_written`.
    def render_header(columns = nil)
      @mapping.render_header(columns)
    end

    # Returns [Array<String>] the columns of the header row once they are cleansed, see
    # `IOStreams::Tabular::Header#cleanse!`.
    #
    # Raises ArgumentError with a schema, whose fields name the keys of the records read instead, so that the header
    # keeps the header row as it was read, see `IOStreams::Tabular::SchemaMapping`.
    def cleanse_header!
      @mapping.cleanse_header!
    end

    # Parses the header row, then cleanses its columns, see `IOStreams::Tabular::Header#cleanse!`.
    #
    # With a schema, matches its columns to the fields instead, see `IOStreams::Schema::Columns#match`. The header columns
    # are the header row as it was read, so that another Tabular with the same schema, such as one that reads the rest of
    # the file elsewhere, matches the same columns with `read_header(header.columns)`.
    #
    # Without a schema, the header row of a format of keyed records, such as JSON, is the keys of the record of the line,
    # or the row of keys supplied, such as the header row that #read_row yielded, as they are, as the keys of its records
    # are.
    #
    # Returns [Array] the header row as read, before it is cleansed, or with a schema, the names of the fields of its
    # columns, in the order of the fields.
    # Returns nil when the line is blank, or the format does not have a header row.
    def read_header(line)
      @mapping.read_header(line)
    end

    # Raises ArgumentError when nothing names the keys of the records of the file, see #unnamed_columns?, so that a reader
    # or writer of records raises before the file is opened, see `IOStreams::Record::Reader` and
    # `IOStreams::Record::Writer`.
    def check_records
      return unless unnamed_columns?

      raise(ArgumentError, "The #{format.inspect} rows have no header row, and no keys, so the keys of their records " \
                           "are named by a schema: set one, whose fields name them")
    end

    # Returns [true|false] whether nothing names the columns of the rows: rows without a header row that have no keys,
    # such as those of `:lines`, or of a slice of CSV without a header row, see `headerless:` of #initialize, without a
    # schema, whose fields would name them, so that its records cannot be keyed, see #check_records, and its rows cannot
    # give a writer their columns, see #check_unnamed_rows.
    def unnamed_columns?
      @mapping.unnamed_columns?
    end

    # Raises ArgumentError when a writer of rows would take the columns of the rows from the first row written, writing
    # it as the header row, see #render_row, such as CSV or JSON without a schema, for rows whose columns nothing names,
    # see #unnamed_columns?, such as the lines of the :lines format, or the rows of a slice without a header row, without
    # a schema, so that the first of them is not made the header row: before a copy opens its target, see
    # `IOStreams::Stream#check_unnamed_rows`, and before `IOStreams::Slice::Writer` writes the rows of its first slice.
    def check_unnamed_rows
      return unless @mapping.first_row_header?

      raise(ArgumentError, "The rows written have no header row, and no schema names their columns, as for the lines " \
                           "of the :lines format, or a slice without a header row, so the first of them would be the " \
                           "header row of the #{format.inspect} format: set a schema, whose fields name the columns")
    end

    # Returns [Hash<String,Object>] the line as a record, see #record_parse, which a reader of records reads after the
    # header row, see #read_record_line.
    # Returns nil if the line is blank.
    def read_record(line)
      @mapping.record_parse(line)
    end

    # Reading and writing a line at a time: a reader or writer of rows or records, see `IOStreams::Row::Reader` and the
    # others, hands each line or value to these, which decide whether it is the header row, as the mapping of the
    # columns answers, see `IOStreams::Tabular::Mapping`, so that the reader or writer only iterates.

    # Yields [Array|nil] each row of the line of a file of rows: the header row, while it is expected, see #header?,
    # which it reads, see #read_header, otherwise the row, see #row_parse, or nil for a blank line. The rows of a file
    # whose header row is not a line of its own, see #rows_header?, start with it, before the row of its first line,
    # since it names the column of each value of the rows: the keys of the first record of a format of keyed records,
    # such as JSON without a schema, or the names of the fields of a file without a header row, such as fixed width, or
    # JSON with a schema, see `IOStreams::Tabular::Mapping#read_rows_header`.
    #
    # The header row is an `IOStreams::Row::HeaderRow`, so that a writer of rows takes it as the header row of the rows
    # after it, see `IOStreams::Row::Writer#<<`.
    #
    # Returns the result of the block.
    def read_row(line)
      # Once the header row is read, every line is a row, so that is asked first.
      return yield(@mapping.row_parse(line)) unless @mapping.rows_header?
      return yield(as_header_row(@mapping.read_header(line))) if @mapping.header?

      columns = as_header_row(@mapping.read_rows_header(line))
      yield columns if columns
      yield @mapping.row_parse(line)
    end

    # Yields [IOStreams::Row::HeaderRow] the header row that the rows of a file start with when it is not a line of its
    # own, see #rows_header?, such as the keys of the first record of JSON without a schema, from the supplied line of a
    # record that a reader of rows skips, see `resume_at:` of `IOStreams::Row::Reader`, without parsing the values of
    # the record, so that the rows after it have the columns that reading every row gives them. The line of the first
    # record of JSON without a schema is still parsed for its keys, so one that is not valid JSON raises, as reading every
    # row would. Yields nothing for any other record. A line is a record once the header row is no longer expected, see
    # #header?.
    def skip_record(line)
      return unless @mapping.rows_header?

      columns = as_header_row(@mapping.read_rows_header(line))
      yield columns if columns
    end

    # Yields [Hash|nil] the record of the line of a file of records, see #read_record, or nil for a blank line, unless
    # the line is the header row, while it is expected, see #header?, which it reads instead, see #read_header, since it
    # names the keys of the records after it.
    def read_record_line(line)
      if @mapping.header?
        @mapping.read_header(line)
      else
        yield @mapping.record_parse(line)
      end
    end

    # Yields [String|Object] the line as it is, for a reader that hands on the rows of a file without parsing them, to be
    # parsed later, or elsewhere, such as in slices, see `IOStreams::Slice::Reader`, unless the line is the header row,
    # while it is expected, see #header?, which it reads instead, see #read_header, so that the header row is matched to
    # the fields of the schema, or cleansed, before any row is handed on. A row of a format whose rows are not lines,
    # such as Parquet, is yielded as its reader returns it, see #read_rows.
    #
    # With a schema, the keys of the first record of a format of keyed records, such as JSON or Parquet, which has no
    # header row, are matched to the fields in the same way, see `IOStreams::Tabular::Mapping#check_keys`.
    #
    # Returns the result of the block, or nil for the header row.
    def read_line(line)
      if @mapping.header?
        @mapping.read_header(line)
        nil
      else
        @mapping.check_keys(line)
        yield line
      end
    end

    # Yields [String] the header line that a writer of rows writes before the first row, when the file has a header row,
    # see #requires_header?: the names of the fields of a schema, otherwise nothing, since the first row written is the
    # header row, see #render_row.
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
    # from a file with one, such as the file that is copied, see `IOStreams::Row::Reader#copy_to`, or the header row that
    # `IOStreams::Stream#each(:array)` yields: as the first row, see #render_row, unless the header row gives the
    # columns of the rows instead, for a format without a header row, such as JSON or Parquet, see
    # `IOStreams::Tabular::Mapping#columns_from_header_row?`, when it yields nothing.
    def render_header_row(columns, &)
      return render_row(columns, &) unless @mapping.columns_from_header_row?

      @mapping.take_columns(columns)
      nil
    end

    # Yields [String] the header line that a writer of records writes before the first record: the names of the fields
    # of a schema, when the format has a header row, see #requires_header?, otherwise nothing, including when the keys of
    # the first record give the columns, see #render_record.
    def start_records
      yield render_header if @mapping.requires_header? && !@mapping.columns_from_first_row?
    end

    # Yields [String|nil] each line that a writer of records writes for the record: the header line first, once, when
    # the keys of the first record give the columns, since no schema gives them, then the line of the record, see
    # #render, or nil for a blank record, which is written as a blank line.
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
    register_format(:lines, IOStreams::Tabular::Parser::Lines)
    register_format(:parquet, IOStreams::Tabular::Parser::Parquet)
    register_format(:psv, IOStreams::Tabular::Parser::Psv)

    private

    # Returns [IOStreams::Row::HeaderRow] the columns of a header row that #read_row yields, or nil when there are none,
    # such as for a blank line.
    def as_header_row(columns)
      IOStreams::Row::HeaderRow.new(columns) if columns
    end

    # Returns [IOStreams::Tabular::Mapping] the mapping of the columns of the file, see #mapping: by the fields of the
    # schema, otherwise by the header row, which it cleanses. A row whose every value is blank is a blank row unless
    # `blank_rows` is false, the rows have no header row as `headerless` says, and the schema converts the values read
    # unless `typed`, see #initialize.
    def build_mapping(blank_rows, headerless, typed)
      header = Header.new
      if @schema
        SchemaMapping.new(@schema, header: header, parser: parser, format: format, blank_rows: blank_rows,
                                   headerless: headerless, typed: typed)
      else
        HeaderMapping.new(header: header, parser: parser, format: format, blank_rows: blank_rows, headerless: headerless)
      end
    end
  end
end
