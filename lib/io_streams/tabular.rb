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
      autoload :Psv, "io_streams/tabular/parser/psv"
    end

    attr_reader :format, :header, :parser

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
    def initialize(format: nil, file_name: nil, format_options: nil, default_format: :csv, **args)
      @header = Header.new(**args)
      @format = file_name && format.nil? ? self.class.format_from_file_name(file_name) : format
      @format ||= default_format
      raise(Errors::UnknownFormat, "The format cannot be inferred from the file name: #{file_name}") unless @format

      klass   = self.class.parser_class(@format)
      @parser = format_options ? klass.new(**format_options) : klass.new
      @warned = false
    end

    # Returns [true|false] whether a header is still required in order to parse or render the current format.
    def header?
      parser.requires_header? && IOStreams::Utils.blank?(header.columns)
    end

    # Returns [true|false] whether a header row show be rendered on output.
    def requires_header?
      parser.requires_header?
    end

    # Returns [String] the quote character within which the format embeds field delimiters and newlines,
    # such as `"` for CSV, or [nil] when the format has no such quoting.
    #
    # So that the lines of the data are split where this format, which parses them, expects.
    def quote_character
      parser.class.quote_character
    end

    # Returns [String] the encoding that the format reads and writes text in when the caller does not set one on
    # the encode stream, such as "US-ASCII:UTF-8" for fixed width files, or [nil] for the default encoding of the
    # encode stream, UTF-8.
    def encoding
      parser.class.encoding
    end

    # Returns [Array] the header row/line after parsing and cleansing.
    # Returns `nil` if the row/line is blank, or a header is not required for the supplied format (:json, :hash).
    #
    # Notes:
    # * Call `header?` first to determine if the header should be parsed first.
    # * The header columns are set after parsing the row, but the header is not cleansed.
    def parse_header(line)
      return if IOStreams::Utils.blank?(line) || !parser.requires_header?

      header.columns = parser.parse(line)
    end

    # Returns [Hash<String,Object>] the line as a hash.
    # Returns nil if the line is blank.
    def record_parse(line)
      line = row_parse(line)
      header.to_hash(line) if line
    end

    # Returns [Array] the row/line as a parsed Array of values.
    # Returns nil if the row/line is blank.
    def row_parse(line)
      return if IOStreams::Utils.blank?(line)

      parser.parse(line)
    end

    # Renders the output row
    def render(row)
      return if IOStreams::Utils.blank?(row)

      parser.render(row, header)
    end

    # Returns [String] the header rendered for the output format
    # Return nil if no header is required.
    #
    # When columns are supplied they become the header columns first, such as the first row written
    # when the columns were not supplied.
    def render_header(columns = nil)
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

    # Parses the header row, then cleanses its columns when `cleanse`, otherwise applies the column restrictions to
    # them as they are, see #restrict_columns.
    #
    # Returns [Array] the header row as read, before it is cleansed.
    # Returns nil when the line is blank, or the format does not have a header row.
    def read_header(line, cleanse: true)
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
    register_format(:psv, IOStreams::Tabular::Parser::Psv)

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
