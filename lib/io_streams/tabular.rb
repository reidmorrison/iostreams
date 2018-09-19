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
    autoload :Errors, 'io_streams/tabular/errors'
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
    def initialize(format: nil, file_name: nil, **args)
      @header = Header.new(**args)
      klass   =
        if file_name && format.nil?
          self.class.parser_class_for_file_name(file_name)
        else
          self.class.parser_class(format)
        end
      @parser = klass.new
    end

    # Returns [true|false] whether a header row needs to be read first.
    def requires_header?
      parser.requires_header? && IOStreams.blank?(header.columns)
    end

    # Returns [Array] the header row/line after parsing and cleansing.
    # Returns `nil` if the row/line is blank, or a header is not required for the supplied format (:json, :hash).
    #
    # Notes:
    # * Call `parse_header?` first to determine if the header should be parsed first.
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

    # Returns [Array<String>] the cleansed columns
    def cleanse_header!
      header.cleanse!
      header.columns
    end

    # Register a file extension and the reader and writer classes to use to format it
    #
    # Example:
    #   # MyXls::Reader and MyXls::Writer must implement .open
    #   register_extension(:xls, MyXls::Reader, MyXls::Writer)
    def self.register_extension(extension, parser)
      raise(ArgumentError, "Invalid extension #{extension.inspect}") unless extension.nil? || extension.to_s =~ /\A\w+\Z/
      @extensions[extension.nil? ? nil : extension.to_sym] = parser
    end

    # De-Register a file extension
    #
    # Returns [Symbol] the extension removed, or nil if the extension was not registered
    #
    # Example:
    #   register_extension(:xls)
    def self.deregister_extension(extension)
      raise(ArgumentError, "Invalid extension #{extension.inspect}") unless extension.to_s =~ /\A\w+\Z/
      @extensions.delete(extension.to_sym)
    end

    private

    # A registry to hold formats for processing files during upload or download
    @extensions = {}

    def self.parser_class(format)
      @extensions[format.nil? ? nil : format.to_sym] || raise(ArgumentError, "Unknown Tabular Format: #{format.inspect}")
    end

    # Returns the parser to use with tabular for the supplied file_name
    def self.parser_class_for_file_name(file_name)
      extension = nil
      file_name.to_s.split('.').reverse_each do |ext|
        if @extensions.include?(ext.to_sym)
          extension = ext.to_sym
          break
        end
      end
      parser_class(extension)
    end

    register_extension(nil, IOStreams::Tabular::Parser::Csv)
    register_extension(:array, IOStreams::Tabular::Parser::Array)
    register_extension(:csv, IOStreams::Tabular::Parser::Csv)
    register_extension(:fixed, IOStreams::Tabular::Parser::Fixed)
    register_extension(:hash, IOStreams::Tabular::Parser::Hash)
    register_extension(:json, IOStreams::Tabular::Parser::Json)
    register_extension(:psv, IOStreams::Tabular::Parser::Psv)
  end
end
