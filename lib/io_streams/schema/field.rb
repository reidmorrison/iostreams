# frozen_string_literal: true

require "date"
require "json"
require "time"

module IOStreams
  class Schema
    # A field of a schema: its name and type, the text form of its values, and for a fixed width file its position.
    #
    # Properties of a field, as Frictionless defines them:
    #   name: [String|Symbol]
    #     The key of the field in each record, and its column in the header row that is written. Required.
    #     The records read have the names as they are given as their keys, so a Symbol name returns a Symbol key,
    #     whatever the column of the file is, see `IOStreams::Schema#field_for`.
    #
    #   missingValues: [Array<String|Hash>]
    #     The text that is a missing value, read as nil, see `IOStreams::Schema::MissingValues`, which replaces the
    #     missing values of the schema for this field.
    #     Default: those of the schema, `[""]` unless it says otherwise.
    #
    #   constraints: [Hash]
    #     The rules that the values of the field must follow, such as `{required: true}` for a field that must have a
    #     value, both when reading and when writing, see `IOStreams::Schema::Constraints`, unless it allows blank
    #     values, see `allowBlank` below.
    #
    #   type: [String]
    #     "string":   a String. Any other value is written as its text, except a Hash or an Array, which raise.
    #     "integer":  an Integer, such as `-12` or `0042`.
    #     "number":   a BigDecimal, such as `12.50`, `-1.5E3`, `NaN`, `INF` or `-INF`, or a Float with `floatNumber`.
    #                 `Infinity` and `-Infinity`, as Ruby and JavaScript write them, are read too, whatever their case,
    #                 as frictionless-py also reads them, while one that is not finite is written as the Frictionless
    #                 spec spells it, `NaN`, `INF` or `-INF`, except to JSON, which cannot hold it, so that it raises.
    #     "boolean":  true or false, see `trueValues` and `falseValues`, or the number 1 or 0, such as the 1.0 or 0.0 of a
    #                 spreadsheet, or a column of numbers of a Parquet file or a query.
    #     "date":     a Date, written as `2026-10-13` unless `format` is set. A Time or DateTime at midnight, by its own
    #                 clock, as a spreadsheet's date format reads it, is its date, while any other time raises, rather
    #                 than lose its time of day.
    #     "datetime": a Time, written as `2026-10-13T09:30:00Z` unless `format` is set. Without a format it reads ISO 8601
    #                 with seconds, with a space in place of the T, such as `2026-10-13 09:30:00`, and an offset from UTC
    #                 with or without a colon, or of hours alone, such as `+05:30`, `+0530` or `+05`, see #cast_datetime.
    #     "time":     a time of day, a Time on 2000-01-01, as Active Record holds the value of a `time` column, written as
    #                 the time of its own clock, such as `09:30:00`, without its offset from UTC, unless `format` is set.
    #     "duration": an `ActiveSupport::Duration`, as Active Record holds the value of a PostgreSQL `interval`, read from
    #                 and written as ISO 8601, such as `PT8H30M` or `P1M2DT3H`, keeping its months and days apart from its
    #                 seconds. It needs the activesupport gem, which the field loads when it is created.
    #     "object":   a Hash, read from the text of a JSON object, such as `{"a":1}`, and written as that text, or by a
    #                 format of JSON as an object. A Hash is what JSON holds of it, see .json_data, so that its keys are
    #                 Strings, which IOStreams adds, since Frictionless keeps a dict as it is.
    #     "array":    an Array, read from the text of a JSON array, such as `[1,2]`, and written as that text, or by a
    #                 format of JSON as an array. An Array is what JSON holds of it, see .json_data.
    #     "any":      the value as it is read, without converting it, apart from empty text, which is nil.
    #     Default: "any"
    #
    #   format: [String]
    #     For a date, datetime or time, the strptime pattern of its text, such as "%d/%m/%Y", "%Y%m%d%H%M%S" or "%I:%M %p",
    #     in the syntax of Python's strptime, which Frictionless defines: `%Y` reads exactly 4 digits, and `%f` the
    #     microseconds, see `IOStreams::Schema::Pattern`. A pattern that starts with `fmt:` has the prefix removed, so
    #     that "fmt:default" is the default form, as frictionless-py reads it.
    #     Default: "default", the ISO 8601 form above.
    #
    #   trueValues: [Array<String>]
    #     For a boolean, the text that is true. The first one is written. Default: ["true", "True", "TRUE", "1"]
    #
    #   falseValues: [Array<String>]
    #     For a boolean, the text that is false. The first one is written. Default: ["false", "False", "FALSE", "0"]
    #
    #   floatNumber: [true|false]
    #     For a number, whether to return a Float instead of a BigDecimal, as frictionless-py does.
    #     Default: false
    #
    #   groupChar: [String]
    #     For a number or an integer, the text that groups the digits of its whole part, such as "," for `1,234,567`,
    #     which reading removes, and writing places between each group of 3 digits, see
    #     `IOStreams::Schema::NumberText`.
    #     Default: none
    #
    #   decimalChar: [String]
    #     For a number, the text of its decimal point, such as "," for `12,50`.
    #     Default: "."
    #
    #   bareNumber: [true|false]
    #     For a number or an integer, false to read text with other text before or after the number, such as `95%`,
    #     `$12.50` or `EUR 95`, which is removed, and parentheses around it, such as `(12.50)`, which make it negative,
    #     see `IOStreams::Schema::NumberText`. Writing writes the number alone.
    #     Default: true
    #
    # Properties that IOStreams adds:
    #   aliases: [Array<String>]
    #     The other names of the column of this field, such as `["DOB", "Birth Date"]` for the field `date_of_birth`, for
    #     files whose columns are not named the same way, such as spreadsheets made by hand. A column is matched to an
    #     alias as it is to the name, see `IOStreams::Schema#field_for`. The header row that is written has the name.
    #     Default: []
    #
    #   allowBlank: [true|false]
    #     For a field whose `constraints` are `required`, whether its values can be blank: nil, or empty text, while text
    #     of only whitespace is still read as the type of the field. The header row, or each JSON record, must still have
    #     the field, as `required_columns:` checked before v3.0, apart from a JSON record read through a contract alone,
    #     whose missing key is a blank value, but a value is not required, both when reading and when writing. A property
    #     of the field rather than a constraint, since Frictionless defines `required` as a boolean, and a tool reports an
    #     error for a constraint that it does not support, while it accepts other properties of a field. Raises
    #     ArgumentError for a field that is not required, whose values can be blank anyway.
    #     Default: false
    #
    #   decimals: [Integer]
    #     For a number, the number of digits after the decimal point, rounding the value to them, both when reading and
    #     when writing, so that a record read holds the number that is written, see #round.
    #     Default: as many as the value has.
    #
    #   width: [Integer|"remainder"]
    #     For a fixed width file, the number of characters of the field. "remainder" takes the rest of the line,
    #     for the last field only. Formats with delimiters ignore it.
    #
    #   start: [Integer]
    #     For a fixed width file, the position of the first character of the field, counting from 1, as the
    #     specifications of fixed width files do. It skips the characters after the field before it, such as a filler.
    #     Default: right after the field before it.
    #
    #   truncate: [true|false]
    #     For a string in a fixed width file, whether to write only the first `width` characters of a longer value,
    #     instead of raising `IOStreams::Errors::ValueTooLong`.
    #     Default: false
    #
    #   skip: [true|false]
    #     Whether the field only holds the place of its column, such as a column of a file without a header row that
    #     the code does not read, as a `nil` in `columns:` did before v3.0: reading leaves it out of the rows and
    #     records, and writing writes an empty value in its column, or leaves it out of a JSON record. Its column is
    #     still a field when the columns are matched, see `fieldsMatch` in `IOStreams::Schema`. Since its values are
    #     not read, it only takes the properties that place its column, `name`, `aliases`, `width` and `start`, and
    #     the type "any". IOStreams adds this property.
    #     Default: false
    #
    # Properties that only describe the field to people, `title`, `description`, `example` and `rdfType`, are
    # accepted and have no effect, as are the properties of other tools, whose names include a `:`.
    #
    # Any other property raises `ArgumentError`, as does a type that IOStreams does not support yet, such as "year",
    # and the Frictionless properties that it does not support yet, such as `missingValues`, so that a schema never
    # appears to check a value that it does not.
    class Field
      # The types of field that IOStreams supports.
      TYPES = %w[any array boolean date datetime duration integer number object string time].freeze

      # The properties that each type of field accepts, in addition to those that every field accepts.
      TYPE_PROPERTIES = {
        "boolean"  => %w[trueValues falseValues],
        "date"     => %w[format],
        "datetime" => %w[format],
        "integer"  => %w[groupChar bareNumber],
        "number"   => %w[decimals floatNumber groupChar decimalChar bareNumber],
        "string"   => %w[truncate],
        "time"     => %w[format]
      }.freeze

      # The properties that every field accepts.
      PROPERTIES = %w[name type format width start constraints aliases allowBlank skip missingValues].freeze

      # The properties of a field that is skipped, see `skip` above, which place its column.
      SKIP_PROPERTIES = %w[name type width start aliases skip].freeze

      # The properties of a field that lay out a file, its position and how a long value is cut to its width, and whether
      # it only holds the place of its column, which a contract never has, see `IOStreams::Contract`.
      LAYOUT_PROPERTIES = %w[width start truncate skip].freeze

      # The properties of a field that say how a file writes the text of its values, which the target of a copy does not
      # take from its source, since it writes its own, see `IOStreams::Schema#without_text`.
      TEXT_PROPERTIES = %w[format trueValues falseValues groupChar decimalChar bareNumber missingValues].freeze

      # The properties of a field that only describe it to people.
      DESCRIPTIVE_PROPERTIES = %w[title description example rdfType].freeze

      # The properties of a Frictionless field that IOStreams does not support yet.
      UNSUPPORTED_PROPERTIES = %w[categories categoriesOrdered delimiter itemType].freeze

      DEFAULT_TRUE_VALUES  = %w[true True TRUE 1].freeze
      DEFAULT_FALSE_VALUES = %w[false False FALSE 0].freeze

      # The text of the numbers that are not finite, whose case does not matter: Frictionless' `NaN`, `INF` and `-INF`,
      # and `Infinity` and `-Infinity`, as Ruby and JavaScript write them.
      SPECIAL_NUMBERS = {
        "nan"       => Float::NAN,
        "inf"       => Float::INFINITY,
        "-inf"      => -Float::INFINITY,
        "infinity"  => Float::INFINITY,
        "-infinity" => -Float::INFINITY
      }.freeze

      # The types of the values of a column that a source declares, such as a Parquet file or a database query, that a
      # field of each type converts, see #converts?: a value of its own type passes through, and one of another type
      # converts only when nothing is lost, see #cast, such as a whole number to an integer, or a time at midnight to a
      # date. A field of type "any" takes every value, and text, of type "string", is parsed, or a value of type "any"
      # checked, as each one is read, so a field of any type takes them too, apart from a string, which raises for a
      # Hash or an Array, so takes neither an object nor an array.
      CONVERTED_TYPES = {
        "string"   => %w[string any integer number boolean date datetime time duration],
        "integer"  => %w[integer number],
        "number"   => %w[integer number],
        "boolean"  => %w[boolean integer number],
        "date"     => %w[date datetime],
        "datetime" => %w[datetime],
        "time"     => %w[time datetime],
        "duration" => %w[duration],
        "object"   => %w[object],
        "array"    => %w[array]
      }.freeze

      # The most Hashes and Arrays within each other that the value of an object or array field can have, as the json
      # gem's `max_nesting` reads and writes them, so that a deeper one, such as a Hash that holds itself, raises
      # `IOStreams::Errors::InvalidValue`, rather than overflow the stack, see .json_data.
      MAX_NESTING = 100

      # The types whose values are a Hash or an Array, which JSON holds, see #json_structure?.
      JSON_TYPES = %w[object array].freeze

      # The types whose values are numbers. A constant, so that using it does not create an Array each time, as an
      # Array literal does.
      NUMERIC_TYPES = %w[integer number].freeze

      INTEGER  = /\A[+-]?\d+\z/
      # A whole number with a decimal point, such as "12.0", since a spreadsheet stores every number as a double, and the
      # layout of a fixed width file, before v3.0 replaced it with a schema, read the column with `to_i`.
      WHOLE    = /\A([+-]?\d+)\.0*\z/
      NUMBER   = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/
      # A decimal point without digits after it, such as in "12.", which NUMBER accepts, as Ruby 3.4 does, but
      # `Float()` and `BigDecimal()` raise for before Ruby 3.4.
      BARE_POINT = /\.(?=[eE]|\z)/
      DATE     = /\A\d{4}-\d{2}-\d{2}\z/
      # The text of a datetime without a format: ISO 8601 with seconds, below 60, with a T or a space between its date
      # and its time, and an offset from UTC, Z, or the hours, with or without minutes, below 60, with or without a
      # colon between them, such as `+05:30`, `+0530` or `+05`, as PostgreSQL writes it, or none, which is UTC. Its date,
      # its time and its offset are captured.
      DATETIME = /\A(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:[0-5]\d(?:\.\d+)?)(Z|[+-]\d{2}(?::?[0-5]\d)?)?\z/
      # A time of day, with an offset from UTC as a datetime has one, see DATETIME, whose hour, minute and second are
      # checked, see #cast_time, since `Time` moves 24:00:00, and a leap second, into the next day. Its hour, minute,
      # second, fraction of a second and offset are captured.
      TIME     = /\A(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}(?::?[0-5]\d)?)?\z/

      # Returns [String|Symbol] the name of the field, as it was given.
      attr_reader :name

      # Returns [String] the type of the field, such as "integer".
      attr_reader :type

      # Returns [Integer|:remainder|nil] the number of characters of the field in a fixed width file.
      attr_reader :width

      # Returns [Integer|nil] the position of the first character of the field in a fixed width file, counting from 1.
      attr_reader :start

      # Returns [Integer|nil] for a number, the number of digits after the decimal point, see `decimals` above.
      attr_reader :decimals

      # Returns [Array<String>] the other names of the column of this field, see `aliases` above.
      attr_reader :aliases

      # Parameters:
      #   descriptor: [Hash]
      #     The properties of the field, see above, whose keys are Strings or Symbols.
      #
      #   missing_values: [IOStreams::Schema::MissingValues]
      #     The missing values of the schema, which the field's own `missingValues` replaces, see above.
      #     Default: `[""]`
      #
      # Raises ArgumentError when the descriptor is not a valid field.
      def initialize(descriptor, missing_values = MissingValues::DEFAULT) # rubocop:disable Metrics/AbcSize -- one check for each property of a field
        raise(ArgumentError, "A schema field must be a Hash: #{descriptor.inspect}") unless descriptor.is_a?(Hash)

        descriptor = descriptor.transform_keys(&:to_s)
        @name      = descriptor["name"]
        unless @name.is_a?(String) || @name.is_a?(Symbol)
          raise(ArgumentError, "A schema field must have a name: #{descriptor.inspect}")
        end

        # A frozen copy, so that changing the name supplied does not change the field, nor the field the name supplied,
        # and a record read uses it as its key without copying it.
        @name = -@name if @name.is_a?(String)

        @type = (descriptor["type"] || "any").to_s
        check_type
        @skip = check_skip(descriptor)
        check_properties(descriptor)
        @format       = check_format(descriptor["format"])
        @utc          = @type == "datetime" && !@format.nil? && !@format.zone?
        @width        = check_width(descriptor["width"])
        @start        = check_positive("start", descriptor["start"])
        @truncate     = check_flag("truncate", descriptor["truncate"])
        @float        = check_flag("floatNumber", descriptor["floatNumber"])
        @decimals     = check_decimals(descriptor["decimals"])
        @number_text  = number_text_of(descriptor)
        @true_values  = check_values("trueValues", descriptor["trueValues"], DEFAULT_TRUE_VALUES)
        @false_values = check_values("falseValues", descriptor["falseValues"], DEFAULT_FALSE_VALUES)
        @aliases      = check_values("aliases", descriptor["aliases"], [].freeze, empty: true)
        @missing      = own_missing_values(descriptor) || missing_values
        @constraints  = Constraints.new(descriptor["constraints"], @name,
                                        allow_blank: check_flag("allowBlank", descriptor["allowBlank"]))
        @properties   = properties_of(descriptor)
        @hash         = [self.class, @properties, @missing].hash
        require_duration if @type == "duration"
        freeze
      end

      # Returns [Hash] the properties of the field as they were given, with Symbol keys, also within its `constraints`,
      # whether they were given as Strings or Symbols, such as `{name: "amount", type: "number", decimals: 2}`. A new
      # Hash each time, see `IOStreams::Schema#to_h`.
      def to_h
        Utils.deep_copy(@properties)
      end

      # Returns [Array<String>] the properties of this field that lay out a file, see LAYOUT_PROPERTIES.
      def layout_properties
        LAYOUT_PROPERTIES.select { |name| @properties.key?(name.to_sym) }
      end

      # Returns [Hash] the properties of this field without those that lay out a file, see LAYOUT_PROPERTIES, nor the
      # `format` of its text, for a contract, see `IOStreams::Schema#to_contract`.
      def to_contract_h
        to_h.except(*LAYOUT_PROPERTIES.map(&:to_sym), :format)
      end

      # Returns [Hash] the properties of this field without those that say how a file writes the text of its values,
      # see TEXT_PROPERTIES, see `IOStreams::Schema#without_text`.
      def without_text_h
        to_h.except(*TEXT_PROPERTIES.map(&:to_sym))
      end

      # Returns [true|false] whether the other is a field of the same properties, see #to_h, and missing values, which
      # can be those of its schema, see `missingValues` above.
      def ==(other)
        equal?(other) || (other.instance_of?(self.class) && properties == other.properties && missing == other.missing)
      end

      # Returns [true|false] whether the other is a field of the same properties and missing values, compared by `eql?`,
      # as a Hash key is.
      def eql?(other)
        equal?(other) || (other.instance_of?(self.class) && properties.eql?(other.properties) && missing.eql?(other.missing))
      end

      # Returns [Integer] the hash of the properties of the field, worked out once, since a field never changes.
      attr_reader :hash

      # Returns [String] the class and the properties of the field, see #to_h, rather than every instance variable.
      def inspect
        "#<#{self.class.name} #{to_h.inspect}>"
      end

      # Returns [Time] the time of the DateTime, at its offset from UTC.
      #
      # Unlike `DateTime#to_time` in ActiveSupport 7, which converts it to the local time zone of the server, unless
      # `ActiveSupport.to_time_preserves_timezone` is set.
      def self.time_of(datetime)
        seconds = datetime.sec + datetime.sec_fraction
        Time.new(datetime.year, datetime.month, datetime.day, datetime.hour, datetime.minute, seconds,
                 (datetime.offset * 86_400).to_i)
      end

      # Returns [Time] the time of day of the supplied Time, the time of its clock at its offset from UTC, on 2000-01-01,
      # as Active Record holds the value of a `time` column, or the time itself when it is on that day.
      #
      # A time on another day, such as a Parquet time of day, which the `parquet` gem reads on the day that it is read, or
      # an `ActiveSupport::TimeWithZone` of a Rails app, whose time of day can be on 1999-12-31 once Active Record
      # converts it to the time zone of the application, is moved to that day, keeping the time of its clock.
      def self.time_of_day(time)
        return time if time.day == 1 && time.month == 1 && time.year == 2000

        seconds = time.sec + time.subsec
        return Time.utc(2000, 1, 1, time.hour, time.min, seconds) if time.utc?

        Time.new(2000, 1, 1, time.hour, time.min, seconds, time.utc_offset)
      end

      # Returns [String] the text of a value whose type is not known, as a field of type "any" writes it: a BigDecimal
      # as a plain decimal, such as "12.5" rather than "0.125e2", a Float or BigDecimal that is not finite as
      # Frictionless writes it, "NaN", "INF" or "-INF", see .special_text, a Time or DateTime in ISO 8601, such as
      # "2026-10-13T09:30:00Z", with as many digits of its fraction of a second as it needs, a Date in ISO 8601, such as
      # "2026-10-13", a Hash or an Array as JSON, such as `{"a":1}` or `[1,2]`, which the JSON format writes for it,
      # see `IOStreams::Tabular::Parser::Json.generate`, and any other value with `to_s`.
      #
      # Formats of text, such as CSV, write each value that has no field this way, as they do every value of a file
      # without a schema.
      #
      # A Hash or an Array that holds a value that JSON cannot hold, such as `Float::NAN`, is handled as writing it to a
      # JSON file handles it: the json gem raises, while ActiveSupport, which replaces how Ruby writes JSON, writes null.
      def self.any_text(value)
        return value if value.is_a?(String)
        # The most common values first, so that they skip the checks below.
        return value.to_s if value.is_a?(Integer)
        return value.finite? ? value.to_s : special_text(value) if value.is_a?(Float)
        # `is_a?` rather than `case`, which an `ActiveSupport::TimeWithZone` does not match.
        return time_text(value) if value.is_a?(Time)
        return time_text(time_of(value)) if value.is_a?(DateTime)
        return value.iso8601 if value.is_a?(Date)
        return value.finite? ? value.to_s("F") : special_text(value) if value.is_a?(::BigDecimal)
        # The JSON that the JSON format writes, rather than `to_s`, whose text only Ruby reads, and which Ruby 3.4 changed.
        return IOStreams::Tabular::Parser::Json.generate(value) if value.is_a?(::Hash) || value.is_a?(::Array)

        value.to_s
      end

      # Returns the value as JSON holds it when its type is not known, as a field of type "any" writes it: a
      # BigDecimal, Date, Time or DateTime as its text, see .any_text, so that a BigDecimal keeps all of its digits, and
      # every other value as it is, except a `JSON::Fragment`, the text of a JSON value, such as a number that a field
      # writes with all of its digits, see #render, which is an `IOStreams::Schema::JsonNumber`, so that a library that
      # replaces how Ruby writes JSON, such as ActiveSupport, writes it as it is too.
      #
      # A Hash or an Array is returned as it is: the JSON format converts each value within it as it writes it, see
      # `IOStreams::Tabular::Parser::Json.json_value`, which asks this method for each one.
      def self.any_json(value)
        return any_text(value) if textual?(value)
        return JsonNumber.new(value.json) if defined?(::JSON::Fragment) && value.is_a?(::JSON::Fragment)

        value
      end

      # Returns the value as JSON holds it, so that an object or array field reads the same value from a format whose
      # rows are Ruby objects, such as `:hash`, a Parquet file or a query, as from JSON, or the text of JSON: a Hash with
      # String keys, such as "a" for the key `:a`, a Symbol as its text, a BigDecimal, Date, Time or DateTime as the text
      # that IOStreams writes for it to JSON, see .any_json, such as "12.5" or "2026-10-13", and any other value as it
      # is, so that a value of another class, such as a Rational, can differ from the value that its JSON text reads.
      # The values within a Hash or an Array are converted too, in a copy, and the value itself is returned when none of
      # them needs it.
      #
      # Raises `JSON::NestingError`, which #cast_json rescues, for Hashes and Arrays nested more than MAX_NESTING deep,
      # such as one that holds itself.
      def self.json_data(value, depth = 0)
        case value
        when ::Hash then data_hash(value, depth + 1)
        when ::Array then data_array(value, depth + 1)
        when String, Integer, Float, true, false, nil then value
        when Symbol then value.to_s
        else textual?(value) ? any_text(value) : value
        end
      end

      # Returns [Hash] a copy of the hash with String keys and each of its values converted, see .json_data, or the hash
      # itself when none of them needs it.
      def self.data_hash(hash, depth)
        nesting(depth)
        return hash.to_h { |key, item| [key.to_s, json_data(item, depth)] } unless hash.each_key.all?(String)

        copy = nil
        hash.each_pair do |key, item|
          next if json_held?(item)

          data = json_data(item, depth)
          (copy ||= hash.dup)[key] = data unless data.equal?(item)
        end
        copy || hash
      end

      # Returns [Array] a copy of the array with each of its values converted, see .json_data, or the array itself when
      # none of them needs it.
      def self.data_array(array, depth)
        nesting(depth)
        copy = nil
        array.each_with_index do |item, index|
          next if json_held?(item)

          data = json_data(item, depth)
          (copy ||= array.dup)[index] = data unless data.equal?(item)
        end
        copy || array
      end

      # Returns [true|false] whether JSON holds the value as it is, so that .json_data is not called for each one.
      def self.json_held?(value)
        case value
        when String, Integer, Float, true, false, nil then true
        else false
        end
      end

      # Raises `JSON::NestingError` when a Hash or an Array is nested deeper than MAX_NESTING.
      def self.nesting(depth)
        raise(JSON::NestingError, "nesting of #{depth} is too deep") if depth > MAX_NESTING
      end

      # Returns [true|false] whether JSON holds the value as its text, see .any_json.
      def self.textual?(value)
        value.is_a?(Time) || value.is_a?(Date) || value.is_a?(::BigDecimal)
      end

      # Returns [String] the text of a number that is not finite, as Frictionless writes it: "NaN", "INF" or "-INF",
      # rather than Ruby's "Infinity".
      def self.special_text(number)
        return "NaN" if number.nan?

        number.positive? ? "INF" : "-INF"
      end

      # Returns [String] the time in ISO 8601, with as many digits of its fraction of a second as it needs.
      def self.time_text(value)
        value.iso8601(fraction_digits(value))
      end

      # Returns [Integer] the digits of the fraction of a second of the time that its text needs: 0, 3, 6 or 9.
      def self.fraction_digits(time)
        nanoseconds = time.nsec
        if nanoseconds.zero? then 0
        elsif (nanoseconds % 1_000_000).zero? then 3
        elsif (nanoseconds % 1000).zero? then 6
        else 9
        end
      end
      private_class_method :time_text, :data_hash, :data_array, :json_held?, :nesting

      # Returns [true|false] whether a value of the supplied type, which a source declares for a column, such as a Parquet
      # file or a database query, can be one of this field, see CONVERTED_TYPES, so that a column whose values never can,
      # such as a boolean for a number, raises before the first row, see `IOStreams::Schema#check_types`.
      def converts?(source_type)
        return true if type == "any" || (%w[string any].include?(source_type) && type != "string")

        CONVERTED_TYPES.fetch(type).include?(source_type)
      end

      # Returns [true|false] whether the values of this field are numbers, which a fixed width file zero fills.
      def numeric?
        NUMERIC_TYPES.include?(type)
      end

      # Returns [true|false] whether the values of this field are numbers that keep every digit, a BigDecimal: a number
      # field without `floatNumber`.
      def decimal?
        type == "number" && !@float
      end

      # Returns [true|false] whether to write only the first `width` characters of a longer string in a fixed width
      # file.
      def truncate?
        @truncate
      end

      # Returns [true|false] whether a number is a Float rather than a BigDecimal, see `floatNumber` above.
      def float? = @float

      # Returns [true|false] whether the field only holds the place of its column, see `skip` above.
      def skip? = @skip

      # Returns [true|false] whether the header row, or each record, must have the field, and, unless it allows blank
      # values, a value, see `constraints` and `allowBlank` above.
      def required? = @constraints.required?

      # Returns [true|false] whether each value of the field must be present: when it is required, unless it allows
      # blank values, see `constraints` and `allowBlank` above, so that a value of nil, or empty text, raises.
      def value_required? = @constraints.value_required?

      # Returns the value converted to the type of this field, such as the Integer `12` for the text `"0012"`, once the
      # leading and trailing whitespace of text is removed, or nil when the value is nil, or is text that is exactly one
      # of its missing values, see `missingValues` above, in every type, a string and any included, empty text unless
      # the field or its schema says otherwise. A string or any field returns any other text as it is.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value is not one of this type, including text of only
      # whitespace, which is not a missing value, but is not a value of any type other than a string or any, or when a
      # required field has no value: nil, or empty text.
      def cast(value)
        return @constraints.no_value if value.nil?
        return @constraints.no_value(value) if @missing.include?(value)

        case type
        when "any" then return value
        when "string" then return cast_string(value)
        end

        if value.is_a?(String)
          text  = value
          value = value.strip
          return invalid(text) if value.empty?
        end

        cast_value(value)
      end

      # Returns the value of this field that a schema rendered as the value itself, see #render's `:typed` form, such as
      # a record written to a store of slices in the `:hash` format, once the store returns it, converted to the type of
      # this field as #cast converts it. A store that does not keep the class of a value returns it in another form: BSON
      # keeps a duration as its number of seconds, which #cast rejects, since a number on its own does not say what it
      # counts, whereas the value of a duration rendered so is its seconds, as `ActiveSupport::Duration#to_i` gives
      # them, so it is a duration again. Any other form is converted by #cast, such as the Time that BSON returns for a
      # Date, which is a Date again.
      #
      # Raises `IOStreams::Errors::InvalidValue` as #cast does.
      def restore(value)
        return cast(value) unless type == "duration" && value.is_a?(Numeric) && !value.is_a?(::ActiveSupport::Duration)
        return invalid(value) unless value.finite?

        ::ActiveSupport::Duration.build(value)
      end

      # Returns the value of this field in a form that JSON keeps exactly, which #load turns back into it, so that a slice
      # of typed values is the same once a job queue or store has held it as JSON or BSON, see `IOStreams::Slice#to_h`:
      # a number as the text of its digits, without rounding them, such as "12.50" for a field with 2 decimals, or a
      # Float, which JSON keeps, apart from NaN and the infinities, which are text, a date, a datetime and a duration in
      # ISO 8601, a datetime with as many digits of its fraction of a second as it needs and its offset, a time of day as
      # its clock with its offset, such as "09:30:00.250-04:00", and any other value as it is, apart from a time, a date
      # or a BigDecimal of a field of type "any", which JSON holds as its text, see .any_text, and which therefore comes
      # back as that text, since the field does not say what type it is.
      def dump(value)
        return value if value.nil?

        case type
        when "number" then number_dump(value)
        when "date" then value.is_a?(Date) ? value.iso8601 : value
        when "datetime" then value.is_a?(Time) || value.is_a?(DateTime) ? self.class.any_text(value) : value
        when "time" then value.is_a?(Time) ? clock_dump(value) : value
        when "duration" then value.respond_to?(:iso8601) ? value.iso8601 : value
        when "any" then self.class.textual?(value) ? self.class.any_text(value) : value
        else value
        end
      end

      # Returns the value of this field from the form that #dump gives it, in ISO 8601 whatever the `format` of the field,
      # or from any other form that a store returned it in, see #restore.
      #
      # Raises `IOStreams::Errors::InvalidValue` as #restore does.
      def load(value)
        return restore(value) unless value.is_a?(String)

        case type
        when "date" then DATE.match?(value) ? cast_date_text(value) : cast(value)
        when "datetime" then (match = DATETIME.match(value)) ? iso_datetime(match) : cast(value)
        when "time" then (clock = TIME.match(value)) ? iso_clock(clock) : cast(value)
        else restore(value)
        end
      rescue ArgumentError
        invalid(value)
      end

      # Returns [Numeric] the number, of the type of this field, see #cast, rounded to its decimals as its text is
      # written, see #render: a BigDecimal half up, whatever the rounding mode of `BigDecimal.mode`, and a Float as
      # Ruby's `format` writes it, which rounds a Float whose text ends in 5 to the even digit, whatever its binary value,
      # such as 0.12 for 0.125, 0.02 for 0.025 and 2.68 for 2.675, so that a record read, and a format that holds the
      # number itself, such as Parquet, hold the number that CSV writes. A number that rounds to zero is zero, rather
      # than -0.0, which CSV would write as "-0.00". A number that is not finite, or of a field without decimals, is
      # returned as it is.
      def round(number)
        return number if @decimals.nil? || !number.finite?

        rounded = number.is_a?(Float) ? Float(float_text(number)) : number.round(@decimals, :half_up)
        rounded.zero? ? rounded.abs : rounded
      end

      # Returns the value read from a format whose values are in the supplied form, see #render, converted to the type of
      # this field, as #cast converts it, apart from a Hash or an Array of an object or array field read from JSON,
      # `:json`, which is already what JSON holds, so that it is only checked to be of the class of the field, rather
      # than converted again, see .json_data, which takes several times as long as JSON takes to read it.
      #
      # Raises `IOStreams::Errors::InvalidValue` as #cast does.
      def parse(value, form)
        return cast(value) unless form == :json && json_structure?(value)

        value.is_a?(json_class) ? value : invalid(value)
      end

      # Returns the value converted to the type of this field, see #cast, in the form that the supplied format of
      # file writes it:
      #   :text   the text of the value, such as "12.50", for a format of text, such as CSV.
      #   :json   the value as JSON represents it: an integer or boolean as itself, a number as its text, the same as
      #           :text, which JSON writes as it is, see #number_json, and any other value as its text.
      #   :typed  the value itself, such as `BigDecimal("12.5")`, for a format whose rows are Ruby objects, such as
      #           `:hash`.
      #
      # A Hash or an Array of an object or array field is written to JSON, or as its JSON text, as the JSON format
      # converts the values within it, see #render_json_structure, rather than first converted as JSON holds it, see
      # .json_data, which the JSON format does again as it writes it. `:typed` converts it, as #cast does.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value is not one of this type.
      def render(value, form)
        return render_json_structure(value, form) if form != :typed && json_structure?(value)

        value = cast(value)
        return value if value.nil? || form == :typed
        return json(value) if form == :json

        text(value)
      end

      protected

      # Returns [Hash] the frozen properties of the field, for #== and #eql?, without the copy that #to_h makes.
      attr_reader :properties

      # Returns [IOStreams::Schema::MissingValues] the missing values of the field, for #== and #eql?.
      attr_reader :missing

      private

      # Returns the value, which is neither nil nor blank text, converted to the type of this field, other than a string
      # or any field, see #cast.
      def cast_value(value)
        case type
        when "integer" then cast_integer(value)
        when "number" then round(cast_number(value))
        when "boolean" then cast_boolean(value)
        when "date" then cast_date(value)
        when "time" then cast_time(value)
        when "duration" then cast_duration(value)
        when "object" then cast_json(value, ::Hash)
        when "array" then cast_json(value, ::Array)
        else cast_datetime(value)
        end
      end

      # Returns [String] the text of a value of this type, once it is converted, see #cast, such as "12.50" for the
      # number `BigDecimal("12.5")` with 2 decimals.
      def text(value)
        case type
        when "integer" then @number_text ? @number_text.write(value.to_s) : value.to_s
        when "number" then @number_text ? @number_text.write(number_text(value)) : number_text(value)
        when "boolean" then value ? @true_values.first : @false_values.first
        when "date" then @format ? @format.strftime(value) : self.class.any_text(value)
        when "datetime" then @format ? datetime_text(value) : self.class.any_text(value)
        when "time" then time_text(value)
        when "duration" then value.iso8601
        else self.class.any_text(value)
        end
      end

      # Returns [String] the time of day in the format of this field, or as `09:30:00`, with as many digits of its
      # fraction of a second as it needs, such as `09:30:00.250`. Either way it is the time of the clock of the value, at
      # its own offset from UTC, as a Rails app shows it, which the default form does not write, so that a time of the
      # application, an `ActiveSupport::TimeWithZone` on 2000-01-01, is written as the time that its users entered.
      def time_text(time)
        return @format.strftime(time) if @format

        digits = self.class.fraction_digits(time)
        digits.zero? ? time.strftime("%H:%M:%S") : time.strftime("%H:%M:%S.%#{digits}N")
      end

      # Returns [String] the time in the format of this field. Text without a zone is read as UTC, see #parse_time, so a
      # time is written in UTC with a format without a zone, so that it reads back as the same time.
      def datetime_text(time)
        @format.strftime(@utc ? time.getutc : time)
      end

      # Returns [Hash] a frozen copy of the properties, with Symbol keys, also within `constraints`, see #to_h.
      def properties_of(descriptor)
        properties  = descriptor.transform_keys(&:to_sym)
        constraints = properties[:constraints]
        properties[:constraints] = constraints.transform_keys(&:to_sym) if constraints.is_a?(::Hash)
        Utils.frozen_copy(properties)
      end

      # Returns [IOStreams::Schema::MissingValues|nil] the field's own missing values, see `missingValues` above, or nil
      # when it has none, and takes those of its schema.
      def own_missing_values(descriptor)
        return unless descriptor.key?("missingValues")

        MissingValues.new(descriptor["missingValues"], "Field #{name.inspect}:")
      end

      def check_type
        return if TYPES.include?(type)

        raise(ArgumentError, "Field #{name.inspect}: the type #{type.inspect} is not supported") if known_type?

        raise(ArgumentError, "Field #{name.inspect}: unknown type #{type.inspect}")
      end

      # Returns [true|false] whether the type is one that Frictionless defines, but IOStreams does not support yet.
      def known_type?
        %w[list year yearmonth geopoint geojson].include?(type)
      end

      def check_properties(descriptor)
        accepted = PROPERTIES + TYPE_PROPERTIES.fetch(type, [])
        descriptor.each_key do |property|
          next if accepted.include?(property) || DESCRIPTIVE_PROPERTIES.include?(property) || property.include?(":")

          if UNSUPPORTED_PROPERTIES.include?(property)
            raise(ArgumentError, "Field #{name.inspect}: the property #{property.inspect} is not supported")
          end

          types = TYPE_PROPERTIES.select { |_type, properties| properties.include?(property) }.keys
          unless types.empty?
            raise(ArgumentError, "Field #{name.inspect}: #{property.inspect} only applies to a #{types.join(' or ')} field")
          end

          raise(ArgumentError, "Field #{name.inspect}: unknown property #{property.inspect}")
        end
      end

      # Returns [IOStreams::Schema::Pattern|nil] the strptime pattern of a date, datetime or time, or nil for the
      # default form.
      def check_format(format)
        pattern = format.is_a?(String) ? format.delete_prefix("fmt:") : format
        return if pattern.nil? || pattern == "default"

        unless %w[date datetime time].include?(type) && pattern.is_a?(String) && pattern.include?("%")
          raise(ArgumentError, "Field #{name.inspect}: the format #{format.inspect} is not supported for a #{type} field")
        end

        Pattern.new(pattern)
      end

      def check_width(width)
        return :remainder if [:remainder, "remainder"].include?(width)
        return width if width.nil? || (width.is_a?(Integer) && width.positive?)

        raise(ArgumentError, "Field #{name.inspect}: width must be a positive Integer or \"remainder\": #{width.inspect}")
      end

      def check_positive(property, value)
        return value if value.nil? || (value.is_a?(Integer) && value.positive?)

        raise(ArgumentError, "Field #{name.inspect}: #{property} must be a positive Integer: #{value.inspect}")
      end

      # Returns [true|false] whether the field is skipped, see `skip` above.
      #
      # Raises ArgumentError for a property of a field that is skipped other than those that place its column, or a
      # type other than "any", since its values are not read.
      def check_skip(descriptor)
        return false unless check_flag("skip", descriptor["skip"])

        other = descriptor.keys.find do |property|
          !SKIP_PROPERTIES.include?(property) && !DESCRIPTIVE_PROPERTIES.include?(property) && !property.include?(":")
        end
        other ||= "type" unless type == "any"
        return true if other.nil?

        raise(ArgumentError, "Field #{name.inspect}: #{other.inspect} does not apply to a field with skip: true, which " \
                             "only holds the place of its column, since its values are not read")
      end

      def check_flag(property, value)
        return false if value.nil?
        return value if [true, false].include?(value)

        raise(ArgumentError, "Field #{name.inspect}: #{property} must be true or false: #{value.inspect}")
      end

      def check_decimals(decimals)
        return if decimals.nil?
        return decimals if decimals.is_a?(Integer) && !decimals.negative?

        raise(ArgumentError, "Field #{name.inspect}: decimals must be an Integer of 0 or more: #{decimals.inspect}")
      end

      # Returns [IOStreams::Schema::NumberText|nil] the text of the numbers of the field, see `groupChar`, `decimalChar`
      # and `bareNumber` above. A number's decimal point is "." unless its `decimalChar` says otherwise, while an integer
      # has none, so that its `groupChar` can be ".".
      def number_text_of(descriptor)
        decimal_char = descriptor.fetch("decimalChar", NumberText::POINT) if @type == "number"
        NumberText.build(@name, group_char: descriptor["groupChar"], decimal_char: decimal_char,
                                bare_number: descriptor["bareNumber"])
      end

      # Returns [Array<String>] the text of a property, such as the true values of a boolean, each a frozen copy. Empty
      # text raises, since a field never compares it, see #cast, as does an empty Array, unless the property can be
      # `empty`, such as `aliases`, whose default it is.
      def check_values(property, values, default, empty: false)
        return default if values.nil?

        texts = values.is_a?(Array) && (empty || !values.empty?) &&
                values.all? { |value| value.is_a?(String) && !value.empty? }
        return values.map(&:-@).freeze if texts

        raise(ArgumentError, "Field #{name.inspect}: #{property} must be an Array of text that is not empty: #{values.inspect}")
      end

      # ActiveSupport::Duration is loaded, which reads and writes ISO 8601 durations, with the parts of ActiveSupport that
      # it needs, such as some extensions of core classes, but not the whole of ActiveSupport, nor its JSON, so that an
      # application that does not use it otherwise, such as one without Rails, writes JSON as before. Its class is held
      # by the gem, so the field raises when it is not installed, rather than hold a duration of another class.
      def require_duration
        require "active_support/duration"
      rescue LoadError => e
        raise(LoadError, "Field #{name.inspect}: a duration field needs the activesupport gem, whose " \
                         "ActiveSupport::Duration holds its values, so add `gem \"activesupport\"` to the Gemfile: " \
                         "#{e.message}")
      end

      # A Hash or an Array holds several values, rather than one value of text, so it raises. Any other value is its
      # text, such as a `URI` or an id.
      def cast_string(value)
        return value if value.is_a?(String)
        return invalid(value) if value.is_a?(::Hash) || value.is_a?(::Array)

        self.class.any_text(value)
      end

      def cast_integer(value)
        case value
        when Integer then value
        when String then integer_text(value)
        when Float, Rational then value.finite? && value == value.floor ? value.to_i : invalid(value)
        else bigdecimal?(value) && value.finite? && value.frac.zero? ? value.to_i : invalid(value)
        end
      end

      # Returns [Integer] the whole number of the text, which can have a decimal point followed only by zeros, such as
      # "12.0", see WHOLE, once its `groupChar` and `bareNumber` are applied, see `IOStreams::Schema::NumberText`.
      def integer_text(text)
        plain = @number_text ? @number_text.read(text) : text
        return invalid(text) if plain.nil?
        return Integer(plain, 10) if INTEGER.match?(plain)

        whole = WHOLE.match(plain)
        whole ? Integer(whole[1], 10) : invalid(text)
      end

      def cast_number(value)
        return parse_number(value) if value.is_a?(String)
        return invalid(value) unless value.is_a?(Integer) || value.is_a?(Float) || value.is_a?(Rational) || bigdecimal?(value)
        return value.to_f if @float
        return rational_number(value) if value.is_a?(Rational)

        bigdecimal?(value) ? value : BigDecimal(value.to_s)
      end

      # Returns [BigDecimal] the Rational as a decimal. A Rational whose decimal ends, since its denominator has no
      # prime factors other than 2 and 5, such as `1234567890123456789/100r` or `1/2**70r`, keeps every digit, whatever
      # the version of bigdecimal, whose division rounds. Any other, such as `1/3r`, is divided, which rounds it.
      def rational_number(value)
        denominator = value.denominator
        twos        = (denominator & -denominator).bit_length - 1
        rest        = denominator >> twos
        fives       = 0
        while (rest % 5).zero?
          rest  /= 5
          fives += 1
        end
        return BigDecimal(value.numerator) / denominator unless rest == 1

        places = [twos, fives].max
        BigDecimal("#{value.numerator * ((10**places) / denominator)}e-#{places}")
      end

      # Returns [BigDecimal|Float] the number of the text, once its `groupChar`, `decimalChar` and `bareNumber` are
      # applied, see `IOStreams::Schema::NumberText`, or of the text of a number that is not finite, see SPECIAL_NUMBERS.
      def parse_number(text)
        plain = @number_text ? @number_text.read(text) : text
        return number(plain, text) if plain && NUMBER.match?(plain)

        special = SPECIAL_NUMBERS[text.downcase]
        return invalid(text) unless special

        @float ? special : BigDecimal(special.to_s)
      end

      # Returns [BigDecimal|Float] the number of text that NUMBER matches, naming the text as it was read when it is not
      # one.
      def number(text, read = text)
        @float ? Float(text) : BigDecimal(text)
      rescue ArgumentError
        return invalid(read) unless BARE_POINT.match?(text)

        # Before Ruby 3.4, so that "12." is read the same with every version of Ruby.
        number(text.sub(BARE_POINT, ".0"), read)
      end

      # Returns [Hash|Array] the value, which must be of the class of the field, a Hash for an object or an Array for an
      # array, as JSON holds it, see .json_data, or the text of one in JSON, whose numbers are read as JSON reads them
      # without a schema.
      def cast_json(value, klass)
        # The JSON that text reads is already what JSON holds.
        json = value.is_a?(String) ? parse_json(value) : self.class.json_data(value)
        # The value as it was read is named, such as the text of a JSON array for an object field.
        json.is_a?(klass) ? json : invalid(value)
      rescue JSON::NestingError
        invalid(value)
      end

      def parse_json(text)
        JSON.parse(text)
      rescue JSON::ParserError
        invalid(text)
      end

      # Returns [true|false] whether the value is a Hash or an Array of a field of type object or array, which JSON
      # holds as it is, see #parse and #render.
      def json_structure?(value)
        JSON_TYPES.include?(type) && (value.is_a?(::Hash) || value.is_a?(::Array))
      end

      # Returns [Class] the class of the values of an object or array field: Hash or Array.
      def json_class
        type == "object" ? ::Hash : ::Array
      end

      # Returns [String|JSON::Fragment] the JSON text of the Hash or Array of an object or array field, as the JSON
      # format writes it, see `IOStreams::Tabular::Parser::Json.generate`, for `:text`, or that text as JSON writes it
      # as it is, see `IOStreams::Schema::JsonNumber.fragment`, for `:json`, so that the values within it are converted
      # once, by the json gem, see #render.
      #
      # Raises `IOStreams::Errors::InvalidValue` for a value that is not of the class of the field, or that is nested
      # more than MAX_NESTING deep, as JSON reads it, such as a Hash that holds itself.
      def render_json_structure(value, form)
        return invalid(value) unless value.is_a?(json_class)

        text = IOStreams::Tabular::Parser::Json.generate(value)
        form == :json ? JsonNumber.fragment(text) : text
      rescue JSON::NestingError
        invalid(value)
      end

      # Returns [ActiveSupport::Duration] the duration, or the duration of its ISO 8601 text, such as `P1M2DT3H`, whose
      # months and days are kept apart from its seconds, since a month, or a day in a time zone with daylight saving
      # time, has no fixed number of seconds. A number raises, since it does not say what it counts.
      def cast_duration(value)
        return value if value.is_a?(::ActiveSupport::Duration)
        return invalid(value) unless value.is_a?(String)

        ::ActiveSupport::Duration.parse(value)
      rescue ArgumentError
        invalid(value)
      end

      # A number is true when it is 1 and false when it is 0, such as the 1.0 or 0.0 of a spreadsheet, the 1 or 0 of
      # JSON, or the numbers of a column of a Parquet file or a query, whatever the text of `trueValues` and
      # `falseValues`, which a number is not. Any other number raises. IOStreams adds this, since Frictionless reads a
      # boolean only from text, and true or false.
      def cast_boolean(value)
        return value if [true, false].include?(value)
        return true if value.is_a?(String) && @true_values.include?(value)
        return false if value.is_a?(String) && @false_values.include?(value)
        return value == 1 if bit?(value)

        invalid(value)
      end

      # A Date passes through, and a Time or DateTime is a Date only when it is midnight, by its own clock, as a
      # spreadsheet's date format reads it, so that a time of day is never lost, nor a zone guessed: any other time raises.
      def cast_date(value)
        return value if value.instance_of?(Date)
        return midnight(value) if value.is_a?(Time) || value.is_a?(DateTime)
        return value.to_date if value.is_a?(Date)
        return invalid(value) unless value.is_a?(String)
        return parse_time(Date, value) if @format
        return invalid(value) unless DATE.match?(value)

        Date.new(*value.split("-").map { |part| Integer(part, 10) })
      rescue Date::Error
        invalid(value)
      end

      # Returns [Date] the date of a Time or DateTime at midnight, by its own clock.
      #
      # Raises `IOStreams::Errors::InvalidValue` for any other time, whose time of day a date would lose.
      def midnight(time)
        fraction = time.is_a?(Time) ? time.subsec : time.sec_fraction
        return time.to_date if time.hour.zero? && time.min.zero? && time.sec.zero? && fraction.zero?

        invalid(time)
      end

      # `Time` moves a day past the end of its month into the next month, such as February 30 into March 2, so the
      # date is checked first, as a date field does.
      #
      # Text without an offset from UTC is read as UTC, rather than in the time zone of the process, so that a file
      # reads the same on every server.
      def cast_datetime(value)
        return value if value.is_a?(Time)
        return self.class.time_of(value) if value.is_a?(DateTime)
        return invalid(value) unless value.is_a?(String)
        return parse_time(Time, value) if @format

        match = DATETIME.match(value)
        date  = match && match[1]
        return invalid(value) unless date && Date.valid_date?(date[0, 4].to_i, date[5, 2].to_i, date[8, 2].to_i)

        iso_datetime(match)
      rescue ArgumentError
        invalid(value)
      end

      # Returns [Time] the time of day, on 2000-01-01, see .time_of_day: of a Time or a DateTime, at its offset from UTC, or
      # of text such as `09:30:00`, `09:30:00.250`, `09:30:00-05:00` or `09:30:00-0500`, or in the format of this field,
      # which is read at the offset of its zone, or in UTC without one, as a datetime field reads it, see #cast_datetime.
      #
      # Its hour, minute and second are checked, since `Time` moves 24:00:00, and a leap second, into the next day.
      def cast_time(value)
        return self.class.time_of_day(value) if value.is_a?(Time)
        return self.class.time_of_day(self.class.time_of(value)) if value.is_a?(DateTime)
        return invalid(value) unless value.is_a?(String)
        return parse_time_of_day(value) if @format

        clock = TIME.match(value)
        return invalid(value) unless clock && clock_time?(clock[1].to_i, clock[2].to_i, clock[3].to_i)

        iso_clock(clock)
      rescue ArgumentError
        invalid(value)
      end

      # Returns [Time] the time of day of the text read with the strptime pattern of the format, see #parse_time.
      def parse_time_of_day(text)
        parts = @format.parts(text)
        return invalid(text) if parts.nil? || !clock_time?(parts.fetch(:hour, 0), parts.fetch(:min, 0), parts.fetch(:sec, 0))

        self.class.time_of_day(parse_time(Time, text, parts))
      end

      # Returns [true|false] whether the hour, minute and second are those of a clock, from 00:00:00 to 23:59:59.
      def clock_time?(hour, minute, second)
        hour < 24 && minute < 60 && second < 60
      end

      # Returns [Date|Time] the text read with the strptime pattern of the format, which must match all of the text,
      # and whose date must exist, see #cast_datetime, from its parts, see `IOStreams::Schema::Pattern#parts`, which
      # are read unless the caller has already read them.
      #
      # A time is at the offset from UTC that its zone gives, or in UTC without one, see #cast_datetime. A zone whose
      # offset is not known, such as "XYZ", raises, rather than be read in the time zone of the process.
      def parse_time(klass, text, parts = @format.parts(text))
        return invalid(text) if parts.nil?
        if parts[:mon] && parts[:mday] && !Date.valid_date?(parts.fetch(:year, Time.now.year), parts[:mon], parts[:mday])
          return invalid(text)
        end
        return @format.date(text) if klass == Date
        return invalid(text) if parts.key?(:zone) && parts[:offset].nil?

        # A DateTime reads text without an offset as UTC, and knows the offset of every zone that Date._strptime knows,
        # such as "CET", which `Time.strptime` reads in the time zone of the process, as it does text without an offset.
        time = self.class.time_of(@format.datetime(text))
        parts[:offset] ? time : time.utc
      rescue ArgumentError
        invalid(text)
      end

      # Returns [String|Float|Integer] the number in a form that JSON keeps exactly, see #dump: the digits of a BigDecimal,
      # with the decimals of the field when it has fewer, never rounded, a finite Float as it is, and NaN and the
      # infinities as their text.
      def number_dump(value)
        return number_text(value) if value.is_a?(Float) ? !value.finite? : (bigdecimal?(value) && !value.finite?)
        return value unless bigdecimal?(value)

        whole, fraction = value.to_s("F").split(".")
        fraction        = fraction.to_s.sub(/0+\z/, "").ljust(@decimals || 0, "0")
        fraction.empty? ? whole : "#{whole}.#{fraction}"
      end

      # Returns [String] the time of day of its clock with its offset from UTC, see #dump.
      def clock_dump(time)
        digits = self.class.fraction_digits(time)
        clock  = digits.zero? ? time.strftime("%H:%M:%S") : time.strftime("%H:%M:%S.%#{digits}N")
        "#{clock}#{time.utc? ? 'Z' : time.strftime('%:z')}"
      end

      # Returns [Time] the time of the text that DATETIME matched, in UTC without an offset, read with `Time.iso8601`,
      # which reads each form of its offset, such as `+05:30`, `+0530` or `+05`, so that only a space in place of the T
      # is replaced, and Z added to text without an offset.
      def iso_datetime(match)
        Time.iso8601("#{match[1]}T#{match[2]}#{match[3] || 'Z'}")
      end

      # Returns [Time] the time of day, on 2000-01-01, of the text that TIME matched, in UTC without an offset, read with
      # `Time.iso8601`, see #iso_datetime, so that only Z is added to text without an offset.
      def iso_clock(clock)
        Time.iso8601("2000-01-01T#{clock[0]}#{'Z' unless clock[5]}")
      end

      # Returns [Date] the date of ISO 8601 text, see #load.
      def cast_date_text(text)
        Date.new(*text.split("-").map { |part| Integer(part, 10) })
      end

      def number_text(value)
        return self.class.special_text(value) unless value.finite?
        return (@decimals ? float_text(value) : value.to_s) if value.is_a?(Float)
        return value.to_s("F") unless @decimals

        # The value is already rounded to the decimals, see #cast.
        return value.to_i.to_s if @decimals.zero?

        whole, fraction = value.to_s("F").split(".")
        "#{whole}.#{fraction.ljust(@decimals, '0')[0, @decimals]}"
      end

      # Returns [String] the text of a finite Float with the decimals of this field, which `format` rounds as its text
      # reads, a Float whose text ends in 5 to the even digit, whatever its binary value, see #round.
      def float_text(value)
        format("%.#{@decimals}f", value)
      end

      def json(value)
        case type
        when "number" then number_json(value)
        when "integer", "boolean", "string" then value
        when "any", "object", "array" then any_json(value)
        else text(value)
        end
      end

      # Returns the value of a field of type any, object or array as JSON holds it, see .any_json. A Float or BigDecimal
      # that is not finite raises, see #not_finite_json, as it does for a number field, while one inside a Hash or an
      # Array is kept as .any_json gives it.
      def any_json(value)
        return not_finite_json(value) if (value.is_a?(Float) || bigdecimal?(value)) && !value.finite?

        self.class.any_json(value)
      end

      # Returns the number as JSON writes it: its text, see #number_text, which JSON writes as it is, see
      # `IOStreams::Schema::JsonNumber.fragment`, so that a BigDecimal keeps all of its digits, and the digits after the
      # decimal point that the field gives are written, such as `12.50`, the same as in CSV. A Float without `decimals`
      # is itself, which JSON writes with the same digits. A number that is not finite, such as NaN, raises, see
      # #not_finite_json.
      def number_json(value)
        return not_finite_json(value) unless value.finite?
        return value if @decimals.nil? && value.is_a?(Float)

        JsonNumber.fragment(number_text(value))
      end

      # Raises `IOStreams::Errors::InvalidValue` for a number that is not finite, such as NaN, which JSON cannot hold,
      # naming the field, rather than leave it to the JSON writer, where the json gem raises its own exception, and
      # ActiveSupport writes `null`.
      def not_finite_json(value)
        raise(IOStreams::Errors::InvalidValue.new(
                "Field #{name.inspect}: JSON cannot hold a number that is not finite: #{self.class.special_text(value)}",
                field: name, value: value
              ))
      end

      def bigdecimal?(value)
        value.is_a?(::BigDecimal)
      end

      # Returns [true|false] whether the value is the number 1 or 0, an Integer, a Float or a BigDecimal, which a boolean
      # reads, see #cast_boolean.
      def bit?(value)
        (value.is_a?(Integer) || value.is_a?(Float) || bigdecimal?(value)) && (value == 1 || value.zero?)
      end

      def invalid(value)
        text = value.inspect
        text = "#{text[0, 60]}..." if text.length > 63
        raise(IOStreams::Errors::InvalidValue.new("Field #{name.inspect}: #{text} is not a valid #{type}", field: name,
                                                                                                           value: value))
      end
    end
  end
end
