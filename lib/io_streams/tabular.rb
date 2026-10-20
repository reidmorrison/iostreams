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
  #
  # With a schema, see `IOStreams::Stream#schema`, the columns of the file are matched to the fields of the schema,
  # whose names are the keys of the records read, and whose types convert the values read and render those written:
  #
  #   tabular = Tabular.new(schema: IOStreams::Schema.new(fields: [{name: "id", type: "integer"}, {name: "name"}]))
  #   tabular.read_header("ID,Name")
  #   # => ["id", "name"]
  #
  #   tabular.record_parse("1,Jack")
  #   # => {"id"=>1, "name"=>"Jack"}
  class Tabular
    autoload :Header, "io_streams/tabular/header"
    autoload :HeaderMapping, "io_streams/tabular/header_mapping"
    autoload :Mapping, "io_streams/tabular/mapping"
    autoload :SchemaMapping, "io_streams/tabular/schema_mapping"

    module Parser
      autoload :Array, "io_streams/tabular/parser/array"
      autoload :Base, "io_streams/tabular/parser/base"
      autoload :Csv, "io_streams/tabular/parser/csv"
      autoload :Fixed, "io_streams/tabular/parser/fixed"
      autoload :FixedFields, "io_streams/tabular/parser/fixed_fields"
      autoload :Hash, "io_streams/tabular/parser/hash"
      autoload :Json, "io_streams/tabular/parser/json"
      autoload :JsonFields, "io_streams/tabular/parser/json_fields"
      autoload :Psv, "io_streams/tabular/parser/psv"
    end

    # The default of the `cleanse_header` option of a reader of rows or records, see `IOStreams::Row::Reader`, which
    # cleanses the header row without a schema. Distinct from true, so that a schema, whose fields name the keys of the
    # records instead, can tell that the option was supplied, see `IOStreams::Tabular::SchemaMapping#read_row`.
    CLEANSE_BY_DEFAULT = :default

    attr_reader :format, :parser

    # Returns [IOStreams::Schema|nil] the schema of the rows and records, see #initialize.
    attr_reader :schema

    # Returns [IOStreams::Tabular::Mapping] the mapping of the columns of the file to the values of its rows and records,
    # by the header row or the columns supplied, or by the fields of a schema, which is chosen when the Tabular is
    # created, see #initialize.
    attr_reader :mapping

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
    #   format_options: [Hash]
    #     Any specialized format specific options. For example, `:fixed` format requires the file definition.
    #
    #   columns [Array<String|Symbol>]
    #     The header columns when the file does not include a header row.
    #     Note:
    #       Column names are converted to strings.
    #
    #   allowed_columns [Array<String>]
    #     List of columns to allow.
    #     Default: nil ( Allow all columns )
    #     Note:
    #       When supplied any columns that are rejected will be returned in the cleansed columns
    #       as nil so that they can be ignored during processing.
    #
    #   required_columns [Array<String>]
    #     List of columns that must be present, otherwise an Exception is raised.
    #
    #   skip_unknown [true|false]
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
    #
    #   schema: [IOStreams::Schema]
    #     The fields of the file, whose names are the keys of each record read, and the type of each one, which converts
    #     the values of each row read, and renders those written, see `IOStreams::Stream#schema`. The columns of the
    #     file are matched to the fields, see `IOStreams::Schema::Columns`, and the schema gives the position of each
    #     field of a fixed width file.
    #     Since the schema describes the columns of the file, the options above that describe them without one,
    #     `columns`, `allowed_columns` and `required_columns`, raise ArgumentError with it, unless they are nil, and so
    #     do `format_options`, unless they are empty, and the `cleanse_header` option of a reader, see
    #     `IOStreams::Row::Reader`. `skip_unknown` only applies to `allowed_columns`, so it does not.
    #     Optional. Default: nil
    #
    #   decoded: [true|false]
    #     With a schema, whether the lines read are already in the encoding of their text, as `IOStreams::Stream` reads
    #     them, see `IOStreams::Builder#utf8_text?`, so that they are taken as they are. Otherwise a binary line, as a
    #     stream reads it without an encoding, is taken as UTF-8, see `IOStreams::Tabular::SchemaMapping`. Raises
    #     ArgumentError without a schema, whose lines are taken as they are.
    #     Default: false
    def initialize(format: nil, file_name: nil, format_options: nil, default_format: :csv, schema: nil, decoded: nil, **args)
      if schema
        reject_schema_options(format_options, args)
      elsif !decoded.nil?
        raise(ArgumentError, "decoded: only applies with a schema, without which the lines are taken as they are")
      end
      header  = Header.new(**args)
      @format = file_name && format.nil? ? self.class.format_from_file_name(file_name) : format
      @format ||= default_format
      raise(Errors::UnknownFormat, "The format cannot be inferred from the file name: #{file_name}") unless @format

      klass   = self.class.parser_class(@format)
      @schema = schema
      if schema
        unless klass.respond_to?(:schema_parser)
          raise(ArgumentError, "The #{@format.inspect} format cannot be read or written with a schema, since its parser " \
                               "is not an IOStreams::Tabular::Parser::Base")
        end

        @parser  = klass.schema_parser(schema)
        @mapping = SchemaMapping.new(schema, header: header, parser: @parser, format: @format, decoded: decoded || false)
      else
        @parser  = format_options ? klass.new(**format_options) : klass.new
        @mapping = HeaderMapping.new(header: header, parser: @parser, format: @format)
      end
    end

    # Returns [IOStreams::Tabular::Header] the columns of the file: the header row read, or the columns supplied in
    # place of one, and their restrictions, see `IOStreams::Tabular::Header`. With a schema, the header row as it was
    # read, see #read_header.
    def header
      @mapping.header
    end

    # Returns [true|false] whether a header is still required in order to parse or render the current format.
    def header?
      @mapping.header?
    end

    # Returns [true|false] whether a header row show be rendered on output: when the format has one, unless the
    # schema says that the file has none, see `IOStreams::Schema#header?`.
    def requires_header?
      @mapping.requires_header?
    end

    # Returns [true|false] whether the rows read start with a header row, see #read_row, until it is read: the header
    # row of a file with one, see #header?, or with a schema, the names of the fields of a file without one, such as
    # fixed width, JSON, or a schema whose `header` is false.
    def rows_header?
      @mapping.rows_header?
    end

    # Returns [Array<String|Symbol>] the columns of the rows of a file without a header row, which #read_row yields as
    # their header row, so that a copy can give them to the target, see `IOStreams::Row::Reader#copy_to`: the names of
    # the fields of a schema, see `IOStreams::Schema#header?`, such as of fixed width or JSON.
    # Returns nil for any other file, such as one whose rows start with a header row of its own, or without a schema.
    def headerless_columns
      @mapping.headerless_columns
    end

    # Returns [Array] the header row/line after parsing and cleansing.
    # Returns `nil` if the row/line is blank, or a header is not required for the supplied format (:json, :hash).
    #
    # Notes:
    # * Call `header?` first to determine if the header should be parsed first.
    # * The header columns are set after parsing the row, but the header is not cleansed.
    # * With a schema, its columns are matched to the fields, see `IOStreams::Schema::Columns#match`.
    def parse_header(line)
      @mapping.parse_header(line)
    end

    # Parses the header row, then cleanses its columns when `cleanse:` is truthy, otherwise applies the column
    # restrictions to them, as a reader of records does, see `IOStreams::Record::Reader`.
    #
    # With a schema, matches its columns to the fields instead, see `IOStreams::Schema::Columns#match`, so `cleanse:`
    # cannot be supplied. The header columns are the header row as it was read, so that another Tabular with the same
    # schema, such as one that parses the rest of the file elsewhere, matches the same columns with
    # `read_header(header.columns)`.
    #
    # Returns [Array] the header row as read, before it is cleansed, or with a schema, the names of the fields of its
    # columns, in the order of the fields.
    # Returns nil when the line is blank, or the format does not have a header row.
    def read_header(line, cleanse: CLEANSE_BY_DEFAULT)
      @mapping.read_header(line, cleanse: cleanse)
    end

    # Returns [Hash<String,Object>] the line as a hash.
    # With a schema, the keys are the names of the fields, and the values are converted to their types, see
    # `IOStreams::Schema::Columns`.
    # Returns nil if the line is blank.
    def record_parse(line)
      @mapping.record_parse(line)
    end

    # Returns [Array] the row/line as a parsed Array of values.
    # With a schema, the values of its fields, in the order of the fields, converted to their types, see
    # `IOStreams::Schema::Columns`.
    # Returns nil if the row/line is blank.
    def row_parse(line)
      @mapping.row_parse(line)
    end

    # Renders the output row
    # With a schema, the value of each field is rendered in the form that the format writes, see
    # `IOStreams::Schema::Field#render`, in the order of the fields.
    def render(row)
      @mapping.render(row)
    end

    # Returns [String] the header rendered for the output format
    # Return nil if no header is required.
    # With a schema, the names of its fields.
    def render_header
      @mapping.render_header
    end

    # Returns [Array<String>] the cleansed columns
    def cleanse_header!
      header.cleanse!
      header.columns
    end

    # Reading and writing a line at a time: a reader or writer of rows or records, see `IOStreams::Row::Reader` and the
    # others, hands each line or value to these, which the mapping of the columns reads or renders, see
    # `IOStreams::Tabular::Mapping`, so that the reader or writer only iterates. Each reading method takes the
    # `cleanse_header` option of the reader as `cleanse:`.

    # Yields [Array|nil] each row of the line of a file of rows: the header row, while it is expected, see #header?,
    # otherwise the row, see #row_parse, or nil for a blank line. With a schema, the header row is an
    # `IOStreams::Row::HeaderRow`, and the rows of a file without one start with the names of the fields, see
    # `IOStreams::Tabular::SchemaMapping#read_row`.
    #
    # Returns the result of the block.
    def read_row(line, cleanse: CLEANSE_BY_DEFAULT, &)
      @mapping.read_row(line, cleanse: cleanse, &)
    end

    # Yields [Hash|nil] the record of the line of a file of records, see #record_parse, or nil for a blank line, unless
    # the line is the header row, while it is expected, see #header?, which it reads instead, see #read_header.
    def read_record_line(line, cleanse: CLEANSE_BY_DEFAULT, &)
      @mapping.read_record_line(line, cleanse: cleanse, &)
    end

    # Applies the column restrictions to the columns supplied in place of a header row, before a reader of records
    # reads the file, see `IOStreams::Record::Reader#initialize`. With a schema no column options apply.
    def restrict_columns(cleanse: CLEANSE_BY_DEFAULT)
      @mapping.restrict_columns(cleanse: cleanse)
    end

    # Yields [String] the header line that a writer of rows writes before the first row: the columns supplied, or with
    # a schema, the names of its fields, when the file has a header row.
    def start_rows(&)
      @mapping.start_rows(&)
    end

    # Yields [String|nil] the line that a writer of rows writes for the row. Without a schema, the first row is the
    # header row, unless the columns were supplied.
    #
    # Returns the result of the block.
    def render_row(row, &)
      @mapping.render_row(row, &)
    end

    # Yields [String|nil] the line that a writer of rows writes for the header row of the rows after it, such as the
    # `IOStreams::Row::HeaderRow` that `IOStreams::Stream#each(:array)` yields with a schema, or the header row of the
    # file that is copied, see `IOStreams::Row::Reader#copy_to`. With a schema, it gives the columns of the rows after
    # it, which are matched to the fields, without a line.
    def render_header_row(columns, &)
      @mapping.render_header_row(columns, &)
    end

    # Yields [String|nil] the line that a writer of rows writes for the columns of the rows after it, which are not a row
    # of the file that they are read from, such as the fields of a file without a header row, see
    # `IOStreams::Row::Reader#copy_to`, as their header row, see #render_header_row, unless the columns were supplied.
    def render_columns(columns, &)
      @mapping.render_columns(columns, &)
    end

    # Yields [String] the header line that a writer of records writes before the first record: the columns supplied,
    # or with a schema, the names of its fields, when the file has a header row.
    def start_records(&)
      @mapping.start_records(&)
    end

    # Yields [String|nil] each line that a writer of records writes for the record. Without a schema, the header line
    # of the keys of the first record comes first, unless the columns were supplied.
    #
    # Returns the result of the block.
    def render_record(record, &)
      @mapping.render_record(record, &)
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
      file_name.to_s.split(".").reverse_each { |ext| return ext.to_sym if @formats.include?(ext.to_sym) }
      nil
    end

    # Returns the parser class for the registered format.
    def self.parser_class(format)
      @formats[format&.to_sym] ||
        raise(ArgumentError, "Unknown Tabular Format: #{format.inspect}")
    end

    register_format(:array, IOStreams::Tabular::Parser::Array)
    register_format(:csv, IOStreams::Tabular::Parser::Csv)
    register_format(:fixed, IOStreams::Tabular::Parser::Fixed)
    register_format(:hash, IOStreams::Tabular::Parser::Hash)
    register_format(:json, IOStreams::Tabular::Parser::Json)
    register_format(:psv, IOStreams::Tabular::Parser::Psv)

    private

    # Raises ArgumentError for the options that describe the columns of a file without a schema, since the schema
    # describes them, see `IOStreams::Schema`, rather than apply one and ignore the other: the options of the header
    # that are not nil, see `IOStreams::Tabular::Header.column_option_names`, the `cleanse_header` option of a reader,
    # even when it is nil, since nil does not cleanse the header row, and the layout of a fixed width file in format
    # options that are not empty.
    #
    # An option that is nil is not supplied, and `skip_unknown` only applies to `allowed_columns`, so they are accepted,
    # so that a caller, such as Rocket Job, can supply its options whether or not there is a schema.
    def reject_schema_options(format_options, args)
      unless format_options.nil? || format_options.empty?
        raise(ArgumentError, "Supply either schema: or format_options:, not both")
      end

      names = Header.column_option_names(args)
      unless names.empty?
        raise(
          ArgumentError,
          "#{names.map { |name| "#{name}:" }.join(', ')} cannot be supplied with a schema, which describes the columns " \
          "of the file: its fields are the columns, `fieldsMatch` says which other columns the file can have, and " \
          "`constraints: {required: true}` which fields it must have, see IOStreams::Schema"
        )
      end
      return unless args.key?(:cleanse_header)

      raise(ArgumentError, "cleanse_header: cannot be supplied with a schema, since the keys of its records are the " \
                           "names of its fields, which the columns of the header row are matched to, see " \
                           "IOStreams::Schema#field_for")
    end
  end
end
