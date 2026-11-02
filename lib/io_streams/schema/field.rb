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
    #                 spreadsheet.
    #     "date":     a Date, written as `2026-10-13` unless `format` is set. A Time or DateTime is its date, dropping its
    #                 time of day, which is deprecated for one that is not at midnight, by its own clock, since v3.0 raises
    #                 for it rather than lose its time of day, see #cast.
    #     "datetime": a Time, written as `2026-10-13T09:30:00Z` unless `format` is set. Without a format it reads ISO 8601
    #                 with seconds, with a space in place of the T, such as `2026-10-13 09:30:00`, and an offset from UTC
    #                 with or without a colon, or of hours alone, such as `+05:30`, `+0530` or `+05`, see #cast_datetime.
    #     "object":   a Hash, read from the text of a JSON object, such as `{"a":1}`, and written as that text, or by a
    #                 format of JSON as an object. A Hash is what JSON holds of it, see .json_data, so that its keys are
    #                 Strings.
    #     "array":    an Array, read from the text of a JSON array, such as `[1,2]`, and written as that text, or by a
    #                 format of JSON as an array. An Array is what JSON holds of it, see .json_data.
    #     "any":      the value as it is read, without converting it.
    #     Default: "any"
    #     Empty text is a missing value, nil, in every type, and text of only whitespace raises in every type but a
    #     string or any, which keep it, see #cast.
    #
    #   format: [String]
    #     For a date or datetime, the strptime pattern of its text, such as "%d/%m/%Y" or "%Y%m%d%H%M%S", in the syntax
    #     of Python's strptime, whose `%Y` reads exactly 4 digits and `%f` microseconds, see
    #     `IOStreams::Schema::Pattern`. A pattern that starts with `fmt:`, as Data Package v0 wrote it, such as
    #     "fmt:%d/%m/%Y", has that prefix removed, as Frictionless says an implementation must, so that "fmt:default" is
    #     the default form.
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
    # Properties that IOStreams adds:
    #   aliases: [Array<String>]
    #     The other names of the column of this field, such as `["DOB", "Birth Date"]` for the field `date_of_birth`, for
    #     files whose columns are not named the same way, such as spreadsheets made by hand. A column is matched to an
    #     alias as it is to the name, see `IOStreams::Schema#field_for`. The header row that is written has the name.
    #     Default: []
    #
    #   allowBlank: [true|false]
    #     For a field whose `constraints` are `required`, whether its values can be blank: nil, or empty text, while text
    #     of only whitespace is not blank, so it is still read as the type of the field, see #cast. The header row, or
    #     each JSON record, must still have the field, as the deprecated `required_columns:` checked, but a value is not
    #     required, both when reading and when writing. A property of the field rather than a constraint,
    #     since Frictionless defines `required` as a boolean, and a tool reports an error for a constraint that it does
    #     not support, while it accepts other properties of a field. Raises ArgumentError for a field that is not
    #     required, whose values can be blank anyway.
    #     Default: false
    #
    #   decimals: [Integer]
    #     For a number, the number of digits written after the decimal point, rounding the value to them.
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
    #     the code does not read, as a `nil` in the deprecated `columns:` did: reading leaves it out of the rows and
    #     records, and writing writes an empty value in its column, or leaves it out of a JSON record. Its column is
    #     still a field when the columns are matched, see `fieldsMatch` in `IOStreams::Schema`. Since its values are
    #     not read, it only takes the properties that place its column, `name`, `aliases`, `width` and `start`, and
    #     the type "any". IOStreams adds this property.
    #     Default: false
    #
    # Properties that only describe the field to people, `title`, `description`, `example` and `rdfType`, are
    # accepted and have no effect, as are the properties of other tools, whose names include a `:`.
    #
    # Any other property raises `ArgumentError`, as does a type that IOStreams does not support yet, such as "time",
    # and the Frictionless properties that it does not support yet, such as `missingValues`, so that a schema never
    # appears to check a value that it does not.
    class Field
      # The types of field that IOStreams supports.
      TYPES = %w[any array boolean date datetime integer number object string].freeze

      # The properties that each type of field accepts, in addition to those that every field accepts.
      TYPE_PROPERTIES = {
        "boolean"  => %w[trueValues falseValues],
        "date"     => %w[format],
        "datetime" => %w[format],
        "number"   => %w[decimals floatNumber],
        "string"   => %w[truncate]
      }.freeze

      # The properties that every field accepts.
      PROPERTIES = %w[name type format width start constraints aliases allowBlank skip].freeze

      # The properties of a field that is skipped, see `skip` above, which place its column.
      SKIP_PROPERTIES = %w[name type width start aliases skip].freeze

      # The properties of a field that only describe it to people.
      DESCRIPTIVE_PROPERTIES = %w[title description example rdfType].freeze

      # The properties of a Frictionless field that IOStreams does not support yet.
      UNSUPPORTED_PROPERTIES = %w[missingValues categories categoriesOrdered decimalChar groupChar
                                  bareNumber delimiter itemType].freeze

      DEFAULT_TRUE_VALUES  = %w[true True TRUE 1].freeze
      DEFAULT_FALSE_VALUES = %w[false False FALSE 0].freeze

      # The text of the numbers that are not finite, whose case does not matter: `NaN`, `INF` and `-INF`, as the
      # Frictionless spec spells them, and `Infinity` and `-Infinity`, as Ruby and JavaScript write them, which
      # frictionless-py also reads.
      SPECIAL_NUMBERS = {
        "nan"       => Float::NAN,
        "inf"       => Float::INFINITY,
        "-inf"      => -Float::INFINITY,
        "infinity"  => Float::INFINITY,
        "-infinity" => -Float::INFINITY
      }.freeze

      # The types whose values are numbers. A constant, so that using it does not create an Array each time, as an
      # Array literal does.
      NUMERIC_TYPES = %w[integer number].freeze

      INTEGER  = /\A[+-]?\d+\z/
      # A whole number with a decimal point, such as "12.0", since a spreadsheet stores every number as a double, and the
      # layout of a fixed width file, see `IOStreams::Stream#format_options`, reads the column with `to_i`.
      WHOLE    = /\A([+-]?\d+)\.0*\z/
      NUMBER   = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/
      # A decimal point without digits after it, such as in "12.", which NUMBER accepts, as Ruby 3.4 does, but
      # `Float()` and `BigDecimal()` raise for before Ruby 3.4.
      BARE_POINT = /\.(?=[eE]|\z)/
      DATE     = /\A\d{4}-\d{2}-\d{2}\z/
      # The text of a datetime without a format: ISO 8601 with seconds, below 60, with a T or a space between its date
      # and its time, and an offset from UTC, Z, or the hours, with or without minutes, below 60, with or without a
      # colon between them, such as `+05:30`, `+0530` or `+05`, as PostgreSQL writes it, or none, which is UTC. The
      # date, the time and the offset are captured.
      DATETIME = /\A(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:[0-5]\d(?:\.\d+)?)(Z|[+-]\d{2}(?::?[0-5]\d)?)?\z/

      # Returns [String|Symbol] the name of the field, as it was given.
      attr_reader :name

      # Returns [String] the type of the field, such as "integer".
      attr_reader :type

      # Returns [Integer|:remainder|nil] the number of characters of the field in a fixed width file.
      attr_reader :width

      # Returns [Integer|nil] the position of the first character of the field in a fixed width file, counting from 1.
      attr_reader :start

      # Returns [Integer|nil] for a number, the number of digits written after the decimal point, see `decimals` above.
      attr_reader :decimals

      # Returns [Array<String>] the other names of the column of this field, see `aliases` above.
      attr_reader :aliases

      # Parameters:
      #   descriptor: [Hash]
      #     The properties of the field, see above, whose keys are Strings or Symbols.
      #
      # Raises ArgumentError when the descriptor is not a valid field.
      def initialize(descriptor) # rubocop:disable Metrics/AbcSize -- one check for each property of a field
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
        @true_values  = check_values("trueValues", descriptor["trueValues"], DEFAULT_TRUE_VALUES)
        @false_values = check_values("falseValues", descriptor["falseValues"], DEFAULT_FALSE_VALUES)
        @aliases      = check_values("aliases", descriptor["aliases"], [].freeze, empty: true)
        @constraints  = Constraints.new(descriptor["constraints"], @name,
                                        allow_blank: check_flag("allowBlank", descriptor["allowBlank"]))
        require_bigdecimal if @type == "number" && !@float
        # Reports the first time that is not at midnight, see #midnight, which the field is frozen without.
        @time_of_day = Deprecation::Once.new if @type == "date"
        freeze
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

      # Returns [String] the text of a value whose type is not known, as a field of type "any" writes it: a BigDecimal
      # as a plain decimal, such as "12.5" rather than "0.125e2", a Float or BigDecimal that is not finite as the
      # Frictionless spec spells it, "NaN", "INF" or "-INF", see .special_text, a Time or DateTime in ISO 8601, such as
      # "2026-10-13T09:30:00Z", with as many digits of its fraction of a second as it needs, a Date in ISO 8601, such as
      # "2026-10-13", a Hash or an Array as JSON, such as `{"a":1}` or `[1,2]`, which is what the JSON format writes
      # for it, see .any_json, and any other value with `to_s`.
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
        return value.finite? ? value.to_s("F") : special_text(value) if defined?(::BigDecimal) && value.is_a?(::BigDecimal)
        # The JSON that the JSON format writes, rather than `to_s`, whose text only Ruby reads, and which Ruby 3.4 changed.
        return any_json(value).to_json if value.is_a?(::Hash) || value.is_a?(::Array)

        value.to_s
      end

      # Returns [String] the text of a number that is not finite, as the Frictionless spec spells it: "NaN", "INF" or
      # "-INF", rather than Ruby's "Infinity".
      def self.special_text(number)
        return "NaN" if number.nan?

        number.positive? ? "INF" : "-INF"
      end

      # Returns the value as JSON holds it when its type is not known, as a field of type "any" writes it: a
      # BigDecimal, Date, Time or DateTime as its text, see .any_text, so that a BigDecimal keeps all of its digits, and
      # every other value as it is, except a `JSON::Fragment`, the text of a JSON value, such as a number that a field
      # writes with all of its digits, see #render, which is an `IOStreams::Schema::JsonNumber`, so that a library that
      # replaces how Ruby writes JSON, such as ActiveSupport, writes it as it is too. The values within a Hash or an
      # Array are converted too, in a copy, and the value itself is returned when none of them needs it.
      def self.any_json(value)
        case value
        when ::Hash then json_hash(value)
        when ::Array then json_array(value)
        when String, Integer, Float, true, false, nil then value
        else
          return any_text(value) if textual?(value)
          return JsonNumber.new(value.json) if defined?(::JSON::Fragment) && value.is_a?(::JSON::Fragment)

          value
        end
      end

      # Returns [Hash] a copy of the hash with each of its values converted, see .any_json, or the hash itself when none
      # of them needs it.
      def self.json_hash(hash)
        copy = nil
        hash.each_pair do |key, item|
          # Skips the call for a value that JSON holds as it is, see .any_json.
          next if item.nil? || item.is_a?(String) || item.is_a?(Integer) || item.is_a?(Float) || item == true || item == false

          json = any_json(item)
          (copy ||= hash.dup)[key] = json unless json.equal?(item)
        end
        copy || hash
      end

      # Returns [Array] a copy of the array with each of its values converted, see .any_json, or the array itself when
      # none of them needs it.
      def self.json_array(array)
        copy = nil
        array.each_with_index do |item, index|
          # Skips the call for a value that JSON holds as it is, see .any_json.
          next if item.nil? || item.is_a?(String) || item.is_a?(Integer) || item.is_a?(Float) || item == true || item == false

          json = any_json(item)
          (copy ||= array.dup)[index] = json unless json.equal?(item)
        end
        copy || array
      end

      # Returns the value as JSON holds it, as Rails' `as_json` gives it, so that an object or array field reads the same
      # value from a format whose rows are Ruby objects, such as `:hash`, as from JSON, or the text of JSON: a Hash with
      # String keys, such as "a" for the key `:a`, a Symbol as its text, a BigDecimal, Date, Time or DateTime as the text
      # that IOStreams writes for it to JSON, see .any_json, such as "12.5" or "2026-10-13", and any other value as it
      # is. The values within a Hash or an Array are converted too, in a copy, and the value itself is returned when
      # none of them needs it.
      def self.json_data(value)
        case value
        when ::Hash then data_hash(value)
        when ::Array then data_array(value)
        when String, Integer, Float, true, false, nil then value
        when Symbol then value.to_s
        else textual?(value) ? any_text(value) : value
        end
      end

      # Returns [Hash] a copy of the hash with String keys and each of its values converted, see .json_data, or the hash
      # itself when none of them needs it.
      def self.data_hash(hash)
        return hash.to_h { |key, item| [key.to_s, json_data(item)] } unless hash.each_key.all?(String)

        copy = nil
        hash.each_pair do |key, item|
          data = json_data(item)
          (copy ||= hash.dup)[key] = data unless data.equal?(item)
        end
        copy || hash
      end

      # Returns [Array] a copy of the array with each of its values converted, see .json_data, or the array itself when
      # none of them needs it.
      def self.data_array(array)
        copy = nil
        array.each_with_index do |item, index|
          data = json_data(item)
          (copy ||= array.dup)[index] = data unless data.equal?(item)
        end
        copy || array
      end

      # Returns [true|false] whether JSON holds the value as its text, see .any_json.
      def self.textual?(value)
        value.is_a?(Time) || value.is_a?(Date) || (defined?(::BigDecimal) && value.is_a?(::BigDecimal))
      end

      # Returns [String] the time in ISO 8601, with as many digits of its fraction of a second as it needs.
      def self.time_text(value)
        nanoseconds = value.nsec
        digits      =
          if nanoseconds.zero? then 0
          elsif (nanoseconds % 1_000_000).zero? then 3
          elsif (nanoseconds % 1000).zero? then 6
          else 9
          end
        value.iso8601(digits)
      end
      private_class_method :time_text, :json_hash, :json_array, :data_hash, :data_array, :textual?

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

      # Returns the value converted to the type of this field, such as the Integer `12` for the text `"0012"`, or nil
      # when the value is missing: nil, or empty text, which Frictionless' default `missingValues`, `[""]`, makes a
      # missing value in every type, including a string. Text of only whitespace is not missing: a string or any field
      # keeps it as the text, and any other type raises for it, as it does for text that is not one of its values. The
      # leading and trailing whitespace of any other text is removed before it is read, except by a string or any field,
      # which keeps the text as it is.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value is not one of this type, or when a required field has
      # no value: nil, or empty text.
      def cast(value)
        return @constraints.no_value if value.nil? || (value.is_a?(String) && value.empty?)

        case type
        when "any" then return value
        when "string" then return cast_string(value)
        end

        if value.is_a?(String)
          text = value.strip
          return invalid(value) if text.empty?

          value = text
        end

        case type
        when "integer" then cast_integer(value)
        when "number" then cast_number(value)
        when "boolean" then cast_boolean(value)
        when "date" then cast_date(value)
        when "object" then cast_json(value, ::Hash)
        when "array" then cast_json(value, ::Array)
        else cast_datetime(value)
        end
      end

      # Returns [Numeric] the number, of the type of this field, see #cast, rounded to its decimals as its text is
      # written, see #render: a BigDecimal half up, which is an Integer with no decimals, and a Float as Ruby's `format`
      # rounds it, to the nearest of its binary value, so that a format that holds the number itself, such as `:hash`,
      # holds the number that CSV writes. A number that is not finite, or of a field without decimals, is returned as it
      # is.
      def round(number)
        return number if @decimals.nil? || !number.finite?

        number.is_a?(Float) ? Float(float_text(number)) : number.round(@decimals)
      end

      # Returns the value converted to the type of this field, see #cast, in the form that the supplied format of
      # file writes it:
      #   :text   the text of the value, such as "12.50", for a format of text, such as CSV.
      #   :json   the value as JSON represents it: an integer or boolean as itself, a number as its text, the same as
      #           :text, which JSON writes as it is, see #number_json, and any other value as its text.
      #   :typed  the value itself, such as `BigDecimal("12.5")`, for a format whose rows are Ruby objects, such as
      #           `:hash`.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value is not one of this type.
      def render(value, form)
        value = cast(value)
        return value if value.nil? || form == :typed
        return json(value) if form == :json

        text(value)
      end

      private

      # Returns [String] the text of a value of this type, once it is converted, see #cast, such as "12.50" for the
      # number `BigDecimal("12.5")` with 2 decimals.
      def text(value)
        case type
        when "number" then number_text(value)
        when "boolean" then value ? @true_values.first : @false_values.first
        when "date" then @format ? @format.strftime(value) : self.class.any_text(value)
        when "datetime" then @format ? datetime_text(value) : self.class.any_text(value)
        else self.class.any_text(value)
        end
      end

      # Returns [String] the time in the format of this field. Text without a zone is read as UTC, see #parse_time, so a
      # time is written in UTC with a format without a zone, so that it reads back as the same time.
      def datetime_text(time)
        @format.strftime(@utc ? time.getutc : time)
      end

      def check_type
        return if TYPES.include?(type)

        raise(ArgumentError, "Field #{name.inspect}: the type #{type.inspect} is not supported") if known_type?

        raise(ArgumentError, "Field #{name.inspect}: unknown type #{type.inspect}")
      end

      # Returns [true|false] whether the type is one that Frictionless defines, but IOStreams does not support yet.
      def known_type?
        %w[list time year yearmonth duration geopoint geojson].include?(type)
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

      # Returns [IOStreams::Schema::Pattern|nil] the strptime pattern of a date or datetime, without the prefix `fmt:`
      # that Data Package v0 wrote before it, or nil for the default form, also after that prefix, as frictionless-py
      # reads `fmt:default`.
      def check_format(format)
        pattern = format.is_a?(String) ? format.delete_prefix("fmt:") : format
        return if pattern.nil? || pattern == "default"

        unless %w[date datetime].include?(type) && pattern.is_a?(String) && pattern.include?("%")
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

      # The bigdecimal gem is a default gem before Ruby 3.4, and a bundled gem since, so it is loaded only when a
      # number field needs it.
      def require_bigdecimal
        require "bigdecimal"
      rescue LoadError => e
        raise(LoadError, "Field #{name.inspect}: a number field needs the bigdecimal gem, so add `gem \"bigdecimal\"` to " \
                         "the Gemfile, or set `floatNumber: true` to return a Float: #{e.message}")
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
      # "12.0", see WHOLE.
      def integer_text(text)
        return Integer(text, 10) if INTEGER.match?(text)

        whole = WHOLE.match(text)
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

      def parse_number(text)
        return number(text) if NUMBER.match?(text)

        special = SPECIAL_NUMBERS[text.downcase]
        return invalid(text) unless special

        @float ? special : BigDecimal(special.to_s)
      end

      # Returns [BigDecimal|Float] the number of text that NUMBER matches.
      def number(text)
        @float ? Float(text) : BigDecimal(text)
      rescue ArgumentError
        return invalid(text) unless BARE_POINT.match?(text)

        # Before Ruby 3.4, so that "12." is read the same with every version of Ruby.
        number(text.sub(BARE_POINT, ".0"))
      end

      # Returns [Hash|Array] the value, which must be of the class of the field, a Hash for an object or an Array for an
      # array, as JSON holds it, see .json_data, or the text of one in JSON, whose numbers are read as JSON reads them
      # without a schema.
      def cast_json(value, klass)
        json = value.is_a?(String) ? parse_json(value) : value
        json = self.class.json_data(json) if json.is_a?(klass)
        # The value as it was read is named, such as the text of a JSON array for an object field.
        json.is_a?(klass) ? json : invalid(value)
      end

      def parse_json(text)
        JSON.parse(text)
      rescue JSON::ParserError
        invalid(text)
      end

      # A number is true when it is 1 and false when it is 0, such as the 1.0 or 0.0 of a spreadsheet, or the 1 or 0 of
      # JSON, whatever the text of `trueValues` and `falseValues`, which a number is not. Any other number raises.
      def cast_boolean(value)
        return value if [true, false].include?(value)
        return true if value.is_a?(String) && @true_values.include?(value)
        return false if value.is_a?(String) && @false_values.include?(value)
        return value == 1 if (value.is_a?(Integer) || value.is_a?(Float)) && (value == 1 || value.zero?)

        invalid(value)
      end

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

      # Returns [Date] the date of a Time or DateTime, dropping its time of day.
      #
      # A time that is not at midnight, by its own clock, is deprecated, since v3.0 raises
      # `IOStreams::Errors::InvalidValue` for it, rather than lose its time of day, while it takes one at midnight, such as
      # the time that a spreadsheet's date format gives, as its date. The first one that the field converts reports a
      # deprecation warning, rather than each one, which would report one for each row of a file, see
      # #time_of_day_warning.
      def midnight(time)
        @time_of_day.warn { time_of_day_warning(time) }
        time.to_date
      end

      # Returns [String|nil] the deprecation warning of a time that a date field converts, see #midnight, or nil for one
      # at midnight, by its own clock.
      def time_of_day_warning(time)
        fraction = time.is_a?(Time) ? time.subsec : time.sec_fraction
        return if time.hour.zero? && time.min.zero? && time.sec.zero? && fraction.zero?

        "a #{time.class.name} that is not at midnight is deprecated for the date field #{name.inspect}, which drops its " \
          "time of day, since v3.0 raises IOStreams::Errors::InvalidValue for it rather than lose it: convert it to a " \
          "Date in the time zone that it belongs to, such as with #to_date, or give the field the type datetime"
      end

      # `Time` moves a day past the end of its month into the next month, such as February 30 into March 2, so the
      # date is checked first, as a date field does.
      #
      # Text without an offset from UTC is read as UTC, rather than in the time zone of the process, so that a file
      # reads the same on every server.
      #
      # Text without a format must match DATETIME, and is read with `Time.iso8601`, which reads each form of its offset,
      # so that only a space in place of the T is replaced, and Z added to text without an offset.
      def cast_datetime(value)
        return value if value.is_a?(Time)
        return self.class.time_of(value) if value.is_a?(DateTime)
        return invalid(value) unless value.is_a?(String)
        return parse_time(Time, value) if @format

        date, time, offset = DATETIME.match(value)&.captures
        return invalid(value) unless date && Date.valid_date?(date[0, 4].to_i, date[5, 2].to_i, date[8, 2].to_i)

        Time.iso8601("#{date}T#{time}#{offset || 'Z'}")
      rescue ArgumentError
        invalid(value)
      end

      # Returns [Date|Time] the text read with the strptime pattern of the format, which must match all of the text,
      # see `IOStreams::Schema::Pattern#parts`, and whose date must exist, see #cast_datetime.
      #
      # A time is at the offset from UTC that its zone gives, or in UTC without one, see #cast_datetime. A zone whose
      # offset is not known, such as "XYZ", raises, rather than be read in the time zone of the process.
      def parse_time(klass, text)
        parts = @format.parts(text)
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

      def number_text(value)
        return self.class.special_text(value) unless value.finite?
        return (@decimals ? float_text(value) : value.to_s) if value.is_a?(Float)
        return value.to_s("F") unless @decimals

        # Rounding to no decimals returns an Integer.
        rounded = round(value)
        return rounded.to_s if rounded.is_a?(Integer)

        whole, fraction = rounded.to_s("F").split(".")
        "#{whole}.#{fraction.ljust(@decimals, '0')[0, @decimals]}"
      end

      # Returns [String] the text of a finite Float with the decimals of this field, which `format` rounds to the nearest
      # of its binary value.
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
        raise(IOStreams::Errors::InvalidValue,
              "Field #{name.inspect}: JSON cannot hold a number that is not finite: #{self.class.special_text(value)}")
      end

      def bigdecimal?(value)
        defined?(::BigDecimal) && value.is_a?(::BigDecimal)
      end

      def invalid(value)
        text = value.inspect
        text = "#{text[0, 60]}..." if text.length > 63
        raise(IOStreams::Errors::InvalidValue, "Field #{name.inspect}: #{text} is not a valid #{type}")
      end
    end
  end
end
