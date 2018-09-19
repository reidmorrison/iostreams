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

    attr_reader :format
    attr_accessor :header, :parser

    # Returns a parser for parsing and rendering the specified format.
    def self.parser_for(format)
      constantize_symbol(format).new
    end

    # Parse a delimited data source.
    #
    # Parameters
    #   format: [Symbol]
    #     :csv, :hash, :array, :json, :psv, :fixed
    #
    #   For all other parameters, see Tabular::Header.new
    def initialize(format: :csv, **args)
      @header = Header.new(**args)
      @format = format
      @parser = self.class.parser_for(format)
    end

    # Returns [true|false] whether a header row needs to be read first.
    def requires_header?
      parser.requires_header? && self.class.blank?(header.columns)
    end

    def format=(format)
      @format = format
      @parser = self.class.parser_for(format)
    end

    # Returns [Array] the header row/line after parsing and cleansing.
    # Returns `nil` if the row/line is blank, or a header is not required for the supplied format (:json, :hash).
    #
    # Notes:
    # * Call `parse_header?` first to determine if the header should be parsed first.
    # * The header columns are set after parsing the row, but the header is not cleansed.
    def parse_header(line)
      return if self.class.blank?(line) || !parser.requires_header?

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
      return if self.class.blank?(line)

      parser.parse(line)
    end

    # Renders the output row
    def render(row)
      return if self.class.blank?(row)

      parser.render(row, header)
    end

    # Returns [Array<String>] the cleansed columns
    def cleanse_header!
      header.cleanse!
      header.columns
    end

    private

    def self.constantize_symbol(symbol, namespace = 'IOStreams::Tabular::Parser')
      klass = "#{namespace}::#{camelize(symbol.to_s)}"
      begin
        if RUBY_VERSION.to_i >= 2
          Object.const_get(klass)
        else
          klass.split('::').inject(Object) { |o, name| o.const_get(name) }
        end
      rescue NameError
        raise(ArgumentError, "Could not convert symbol: #{symbol.inspect} to a class in: #{namespace}. Looking for: #{klass}")
      end
    end

    # Borrow from Rails, when not running Rails
    def self.camelize(term)
      string = term.to_s
      string = string.sub(/^[a-z\d]*/, &:capitalize)
      string.gsub!(/(?:_|(\/))([a-z\d]*)/i) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).capitalize}" }
      string.gsub!('/'.freeze, '::'.freeze)
      string
    end

    def self.blank?(value)
      if value.nil?
        true
      elsif value.is_a?(String)
        value !~ /\S/
      else
        value.respond_to?(:empty?) ? value.empty? : !value
      end
    end
  end
end
