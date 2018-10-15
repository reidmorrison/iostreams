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
    autoload :Header, 'io_streams/tabular/header'

    module Parser
      autoload :Array, 'io_streams/tabular/parser/array'
      autoload :Base, 'io_streams/tabular/parser/base'
      autoload :Csv, 'io_streams/tabular/parser/csv'
      autoload :Fixed, 'io_streams/tabular/parser/fixed'
      autoload :Hash, 'io_streams/tabular/parser/hash'
      autoload :Json, 'io_streams/tabular/parser/json'
      autoload :Psv, 'io_streams/tabular/parser/psv'
    end

    module Utility
      autoload :CSVRow, 'io_streams/tabular/utility/csv_row'
    end

    attr_reader :format, :header, :parser

    # Parse a delimited data source.
    #
    # Parameters
    #   format: [Symbol]
    #     :csv, :hash, :array, :json, :psv, :fixed
    #
    #   For all other parameters, see Tabular::Header.new
    def initialize(format: nil, file_name: nil, format_options: nil, **args)
      @header = Header.new(**args)
      klass   =
        if file_name && format.nil?
          self.class.parser_class_for_file_name(file_name)
        else
          self.class.parser_class(format)
        end
      @parser = format_options ? klass.new(format_options) : klass.new
    end

    # Returns [true|false] whether a header is still required in order to parse or render the current format.
    def header?
      parser.requires_header? && IOStreams.blank?(header.columns)
    end

    # Returns [true|false] whether a header row show be rendered on output.
    def requires_header?
      parser.requires_header?
    end

    # Returns [Array] the header row/line after parsing and cleansing.
    # Returns `nil` if the row/line is blank, or a header is not required for the supplied format (:json, :hash).
    #
    # Notes:
    # * Call `header?` first to determine if the header should be parsed first.
    # * The header columns are set after parsing the row, but the header is not cleansed.
    def parse_header(line)
      return if IOStreams.blank?(line) || !parser.requires_header?

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
      return if IOStreams.blank?(line)

      parser.parse(line)
    end

    # Renders the output row
    def render(row)
      return if IOStreams.blank?(row)

      parser.render(row, header)
    end

    # Returns [String] the header rendered for the output format
    # Return nil if no header is required.
    def render_header
      return unless requires_header?

      if IOStreams.blank?(header.columns)
        raise(Errors::MissingHeader, "Header columns must be set before attempting to render a header for format: #{format.inspect}")
      end

      parser.render(header.columns, header)
    end

    # Returns [Array<String>] the cleansed columns
    def cleanse_header!
      header.cleanse!
      header.columns
    end

    # Register a format and the parser class for it.
    #
    # Example:
    #   register_format(:csv, IOStreams::Tabular::Parser::Csv)
    def self.register_format(format, parser)
      raise(ArgumentError, "Invalid format #{format.inspect}") unless format.nil? || format.to_s =~ /\A\w+\Z/
      @formats[format.nil? ? nil : format.to_sym] = parser
    end

    # De-Register a file format
    #
    # Returns [Symbol] the format removed, or nil if the format was not registered
    #
    # Example:
    #   register_extension(:xls)
    def self.deregister_format(format)
      raise(ArgumentError, "Invalid format #{format.inspect}") unless format.to_s =~ /\A\w+\Z/
      @formats.delete(format.to_sym)
    end

    # Returns [Array<Symbol>] the list of registered formats
    def self.registered_formats
      @formats.keys
    end

    private

    # A registry to hold formats for processing files during upload or download
    @formats = {}

    def self.parser_class(format)
      @formats[format.nil? ? nil : format.to_sym] || raise(ArgumentError, "Unknown Tabular Format: #{format.inspect}")
    end

    # Returns the parser to use with tabular for the supplied file_name
    def self.parser_class_for_file_name(file_name)
      format = nil
      file_name.to_s.split('.').reverse_each do |ext|
        if @formats.include?(ext.to_sym)
          format = ext.to_sym
          break
        end
      end
      parser_class(format)
    end

    register_format(nil, IOStreams::Tabular::Parser::Csv)
    register_format(:array, IOStreams::Tabular::Parser::Array)
    register_format(:csv, IOStreams::Tabular::Parser::Csv)
    register_format(:fixed, IOStreams::Tabular::Parser::Fixed)
    register_format(:hash, IOStreams::Tabular::Parser::Hash)
    register_format(:json, IOStreams::Tabular::Parser::Json)
    register_format(:psv, IOStreams::Tabular::Parser::Psv)
  end
end
