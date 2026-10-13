require "json"

module IOStreams
  # The fields of the rows and records of a tabular file and the type of each one, described with a Frictionless Table
  # Schema, see https://datapackage.org/standard/table-schema/, so that reading rows and records returns each value
  # as its type, such as an Integer or a Date, and writing them writes each value in the text form of its type.
  #
  # Supply a schema with `IOStreams::Stream#schema`, as a Hash, or as the path or url of a JSON file. It applies to
  # every tabular format. A fixed width file also needs the `width` of each field, which IOStreams adds to the
  # properties of Frictionless, see `IOStreams::Schema::Field`.
  #
  # Properties at the top level of the schema:
  #   fields: [Array<Hash>]
  #     The fields, in the order of the columns of the file, see `IOStreams::Schema::Field`.
  #
  #   header: [true|false]
  #     Whether the file has a header row, as the `header` of a Frictionless Table Dialect says. When false, the
  #     columns of the file are the fields, in order: reading takes every line as a row, and writing writes no header
  #     row, and the fields in order. A format without a header row, such as JSON or fixed width, ignores it.
  #     Default: true
  #
  #   width: [Integer|"remainder"]
  #     The width of every line of a fixed width file, when it ends after the last field, such as after a filler.
  #     "remainder" accepts lines of any length, ignoring what follows the last field.
  #     Default: the end of the last field.
  #
  # Properties that only describe the schema to people, `$schema`, `title` and `description`, are accepted and have
  # no effect, as are the properties of other tools, whose names include a `:`, such as `"mytool:owner"`. Any other
  # property raises `ArgumentError`, including those of Frictionless that IOStreams does not support yet, such as
  # `primaryKey`, so that a schema never appears to apply a rule that it does not.
  class Schema
    autoload :Field,  "io_streams/schema/field"
    autoload :Source, "io_streams/schema/source"

    # The properties of a schema that IOStreams supports.
    PROPERTIES = %w[fields header width].freeze

    # The properties of a schema that only describe it to people.
    DESCRIPTIVE_PROPERTIES = %w[$schema title description].freeze

    # The properties of a Frictionless Table Schema that IOStreams does not support yet.
    UNSUPPORTED_PROPERTIES = %w[missingValues primaryKey foreignKeys uniqueKeys fieldsMatch].freeze

    # Returns [Array<IOStreams::Schema::Field>] the fields, in the order of the columns of the file.
    attr_reader :fields

    # Returns [Integer|:remainder|nil] the width of every line of a fixed width file, or nil when it ends after the last
    # field.
    attr_reader :width

    # Returns [IOStreams::Schema] the schema of the descriptor read from the supplied path or url, a String or a
    # path, such as `"s3://bucket/schemas/people.json"`, whose text is JSON.
    #
    # Raises ArgumentError when the file is not JSON, or is not a valid schema.
    def self.read(location)
      path = location.is_a?(IOStreams::Stream) ? location : IOStreams.path(location)
      text = path.read
      begin
        new(JSON.parse(text))
      rescue JSON::ParserError, ArgumentError => e
        name = path.respond_to?(:display_name) ? path.display_name : path.inspect
        raise(ArgumentError, "Invalid schema in #{name}: #{e.message}")
      end
    end

    # Parameters:
    #   descriptor: [Hash]
    #     The schema, see above, whose keys are Strings or Symbols.
    #
    # Raises ArgumentError when the descriptor is not a valid schema.
    def initialize(descriptor)
      raise(ArgumentError, "A schema must be a Hash: #{descriptor.inspect}") unless descriptor.is_a?(Hash)

      descriptor = descriptor.transform_keys(&:to_s)
      check_properties(descriptor)
      @fields = build_fields(descriptor["fields"])
      @header = check_header(descriptor["header"])
      @width  = check_width(descriptor["width"])
      @named  = @fields.to_h { |field| [field.name.to_s, field] }
      # So that a field also matches the key that is the same once both are cleansed, like a header row.
      @cleansed = {}
      @fields.each { |field| @cleansed[Tabular::Header.cleanse_column(field.name)] ||= field }
      freeze
    end

    # Returns [true|false] whether the file has a header row, see `header` above.
    def header?
      @header
    end

    # Returns [IOStreams::Schema::Field] the field for the supplied key of a record, or a column of a row: the field
    # with the same name, whether the key is a String or a Symbol, otherwise the field whose name is the same once both
    # are cleansed like a header row, see `IOStreams::Tabular::Header#cleanse!`, so that the field `"first_name"`
    # applies to the column `"First Name"`, and the field `"First Name"` applies to the cleansed column `"first_name"`.
    #
    # Returns nil when no field applies to the key.
    def field(key)
      return if key.nil?

      @named[key.to_s] || @cleansed[Tabular::Header.cleanse_column(key)]
    end

    private

    def check_properties(descriptor)
      descriptor.each_key do |name|
        next if PROPERTIES.include?(name) || DESCRIPTIVE_PROPERTIES.include?(name) || name.include?(":")

        raise(ArgumentError, "The schema property #{name.inspect} is not supported") if UNSUPPORTED_PROPERTIES.include?(name)

        raise(ArgumentError, "Unknown schema property: #{name.inspect}")
      end
    end

    def build_fields(fields)
      raise(ArgumentError, "A schema must have an Array of fields: #{fields.inspect}") unless fields.is_a?(Array)

      fields = fields.collect { |field| Field.new(field) }
      names  = fields.collect { |field| field.name.to_s }
      duplicates = names.select { |name| names.count(name) > 1 }.uniq
      raise(ArgumentError, "Field names must be unique: #{duplicates.join(', ')}") unless duplicates.empty?

      fields
    end

    def check_header(header)
      return true if header.nil?
      return header if [true, false].include?(header)

      raise(ArgumentError, "The schema header must be true or false: #{header.inspect}")
    end

    def check_width(width)
      return if width.nil?
      return :remainder if [:remainder, "remainder"].include?(width)
      return width if width.is_a?(Integer) && width.positive?

      raise(ArgumentError, "The schema width must be a positive Integer or \"remainder\": #{width.inspect}")
    end
  end
end
