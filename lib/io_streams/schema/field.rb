# frozen_string_literal: true

require "date"
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
    #     value, both when reading and when writing, see `IOStreams::Schema::Constraints`.
    #
    #   type: [String]
    #     "string":   a String. Any other value is written as its text, except a Hash or an Array, which raise.
    #     "integer":  an Integer, such as `-12` or `0042`.
    #     "number":   a BigDecimal, such as `12.50`, `-1.5E3`, `NaN`, `INF` or `-INF`, or a Float with `floatNumber`.
    #     "boolean":  true or false, see `trueValues` and `falseValues`.
    #     "date":     a Date, written as `2026-10-13` unless `format` is set.
    #     "datetime": a Time, written as `2026-10-13T09:30:00Z` unless `format` is set.
    #     "any":      the value as it is read, without converting it.
    #     Default: "any"
    #
    #   format: [String]
    #     For a date or datetime, the strptime pattern of its text, such as "%d/%m/%Y" or "%Y%m%d%H%M%S".
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
    # Properties that only describe the field to people, `title`, `description`, `example` and `rdfType`, are
    # accepted and have no effect, as are the properties of other tools, whose names include a `:`.
    #
    # Any other property raises `ArgumentError`, as does a type that IOStreams does not support yet, such as "time",
    # and the Frictionless properties that it does not support yet, such as `missingValues`, so that a schema never
    # appears to check a value that it does not.
    class Field
      # The types of field that IOStreams supports.
      TYPES = %w[any boolean date datetime integer number string].freeze

      # The properties that each type of field accepts, in addition to those that every field accepts.
      TYPE_PROPERTIES = {
        "boolean"  => %w[trueValues falseValues],
        "date"     => %w[format],
        "datetime" => %w[format],
        "number"   => %w[decimals floatNumber],
        "string"   => %w[truncate]
      }.freeze

      # The properties that every field accepts.
      PROPERTIES = %w[name type format width start constraints aliases].freeze

      # The properties of a field that only describe it to people.
      DESCRIPTIVE_PROPERTIES = %w[title description example rdfType].freeze

      # The properties of a Frictionless field that IOStreams does not support yet.
      UNSUPPORTED_PROPERTIES = %w[missingValues categories categoriesOrdered decimalChar groupChar
                                  bareNumber delimiter itemType].freeze

      DEFAULT_TRUE_VALUES  = %w[true True TRUE 1].freeze
      DEFAULT_FALSE_VALUES = %w[false False FALSE 0].freeze

      # The text of the numbers that are not finite, whose case does not matter.
      SPECIAL_NUMBERS = {"nan" => Float::NAN, "inf" => Float::INFINITY, "-inf" => -Float::INFINITY}.freeze

      # The types whose values are numbers. A constant, so that using it does not create an Array each time, as an
      # Array literal does.
      NUMERIC_TYPES = %w[integer number].freeze

      INTEGER  = /\A[+-]?\d+\z/
      NUMBER   = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/
      # A decimal point without digits after it, such as in "12.", which NUMBER accepts, as Ruby 3.4 does, but
      # `Float()` and `BigDecimal()` raise for before Ruby 3.4.
      BARE_POINT = /\.(?=[eE]|\z)/
      DATE     = /\A\d{4}-\d{2}-\d{2}\z/
      DATETIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?\z/

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
        check_properties(descriptor)
        @format       = check_format(descriptor["format"])
        @width        = check_width(descriptor["width"])
        @start        = check_positive("start", descriptor["start"])
        @truncate     = check_flag("truncate", descriptor["truncate"])
        @float        = check_flag("floatNumber", descriptor["floatNumber"])
        @decimals     = check_decimals(descriptor["decimals"])
        @true_values  = check_values("trueValues", descriptor["trueValues"], DEFAULT_TRUE_VALUES)
        @false_values = check_values("falseValues", descriptor["falseValues"], DEFAULT_FALSE_VALUES)
        @aliases      = check_values("aliases", descriptor["aliases"], [].freeze, empty: true)
        @constraints  = Constraints.new(descriptor["constraints"], @name)
        require_bigdecimal if @type == "number" && !@float
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
      # as a plain decimal, such as "12.5" rather than "0.125e2", a Time or DateTime in ISO 8601, such as
      # "2026-10-13T09:30:00Z", with as many digits of its fraction of a second as it needs, a Date in ISO 8601, such as
      # "2026-10-13", and any other value with `to_s`.
      #
      # Formats of text, such as CSV, write each value that has no field this way, as they do every value of a file
      # without a schema.
      def self.any_text(value)
        return value if value.is_a?(String)
        # The most common values first, so that they skip the checks below.
        return value.to_s if value.is_a?(Integer) || value.is_a?(Float)
        # `is_a?` rather than `case`, which an `ActiveSupport::TimeWithZone` does not match.
        return time_text(value) if value.is_a?(Time)
        return time_text(time_of(value)) if value.is_a?(DateTime)
        return value.iso8601 if value.is_a?(Date)
        return value.to_s("F") if defined?(::BigDecimal) && value.is_a?(::BigDecimal)

        value.to_s
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
      private_class_method :time_text, :json_hash, :json_array, :textual?

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

      # Returns [true|false] whether the field must have a value, see `constraints` above.
      def required? = @constraints.required?

      # Returns the value converted to the type of this field, such as the Integer `12` for the text `"0012"`, or nil
      # when the value is nil, or is text that is empty once its leading and trailing whitespace is removed, except
      # for a string or any field, which returns the text as it is.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value is not one of this type, or when a required field has
      # no value: nil, or empty text.
      def cast(value)
        return @constraints.no_value if value.nil?

        case type
        when "any" then return value == "" ? @constraints.no_text(value) : value
        when "string" then return value == "" ? @constraints.no_text(value) : cast_string(value)
        end

        if value.is_a?(String)
          value = value.strip
          return @constraints.no_value if value.empty?
        end

        case type
        when "integer" then cast_integer(value)
        when "number" then cast_number(value)
        when "boolean" then cast_boolean(value)
        when "date" then cast_date(value)
        else cast_datetime(value)
        end
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
        when "date", "datetime" then @format ? value.strftime(@format) : self.class.any_text(value)
        else self.class.any_text(value)
        end
      end

      def check_type
        return if TYPES.include?(type)

        raise(ArgumentError, "Field #{name.inspect}: the type #{type.inspect} is not supported") if known_type?

        raise(ArgumentError, "Field #{name.inspect}: unknown type #{type.inspect}")
      end

      # Returns [true|false] whether the type is one that Frictionless defines, but IOStreams does not support yet.
      def known_type?
        %w[object array list time year yearmonth duration geopoint geojson].include?(type)
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

      # Returns [String|nil] the strptime pattern of a date or datetime, or nil for the default form.
      def check_format(format)
        return if format.nil? || format == "default"

        unless %w[date datetime].include?(type) && format.is_a?(String) && format.include?("%")
          raise(ArgumentError, "Field #{name.inspect}: the format #{format.inspect} is not supported for a #{type} field")
        end

        format
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
        when String then INTEGER.match?(value) ? Integer(value, 10) : invalid(value)
        when Float, Rational then value.finite? && value == value.floor ? value.to_i : invalid(value)
        else bigdecimal?(value) && value.finite? && value.frac.zero? ? value.to_i : invalid(value)
        end
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

      def cast_boolean(value)
        return value if [true, false].include?(value)
        return true if value.is_a?(String) && @true_values.include?(value)
        return false if value.is_a?(String) && @false_values.include?(value)

        invalid(value)
      end

      def cast_date(value)
        return value.to_date if value.is_a?(Date) || value.is_a?(Time)
        return invalid(value) unless value.is_a?(String)
        return parse_time(Date, value) if @format
        return invalid(value) unless DATE.match?(value)

        Date.new(*value.split("-").map { |part| Integer(part, 10) })
      rescue Date::Error
        invalid(value)
      end

      # `Time` moves a day past the end of its month into the next month, such as February 30 into March 2, so the
      # date is checked first, as a date field does.
      def cast_datetime(value)
        return value if value.is_a?(Time)
        return self.class.time_of(value) if value.is_a?(DateTime)
        return invalid(value) unless value.is_a?(String)
        return parse_time(Time, value) if @format
        return invalid(value) unless DATETIME.match?(value)
        return invalid(value) unless Date.valid_date?(value[0, 4].to_i, value[5, 2].to_i, value[8, 2].to_i)

        Time.iso8601(value)
      rescue ArgumentError
        invalid(value)
      end

      # Returns [Date|Time] the text read with the strptime pattern of the format, which must match all of the text,
      # and whose date must exist, see #cast_datetime.
      def parse_time(klass, text)
        parts = Date._strptime(text, @format)
        return invalid(text) if parts.nil? || parts.key?(:leftover)
        if parts[:mon] && parts[:mday] && !Date.valid_date?(parts.fetch(:year, Time.now.year), parts[:mon], parts[:mday])
          return invalid(text)
        end

        klass.strptime(text, @format)
      rescue ArgumentError
        invalid(text)
      end

      def number_text(value)
        return "NaN" if value.nan?
        return value.positive? ? "INF" : "-INF" if value.infinite?
        return (@decimals ? format("%.#{@decimals}f", value) : value.to_s) if value.is_a?(Float)
        return value.to_s("F") unless @decimals

        # Rounding to no decimals returns an Integer.
        rounded = value.round(@decimals)
        return rounded.to_s if rounded.is_a?(Integer)

        whole, fraction = rounded.to_s("F").split(".")
        "#{whole}.#{fraction.ljust(@decimals, '0')[0, @decimals]}"
      end

      def json(value)
        case type
        when "number" then number_json(value)
        when "integer", "boolean", "string" then value
        when "any" then self.class.any_json(value)
        else text(value)
        end
      end

      # Returns the number as JSON writes it: its text, see #number_text, which JSON writes as it is, see
      # `IOStreams::Schema::JsonNumber.fragment`, so that a BigDecimal keeps all of its digits, and the digits after the
      # decimal point that the field gives are written, such as `12.50`, the same as in CSV. A Float without `decimals`
      # is itself, which JSON writes with the same digits, and a number that is not finite, such as NaN, is a Float,
      # which JSON cannot hold, so that the JSON writer raises for it.
      def number_json(value)
        return value.to_f unless value.finite?
        return value if @decimals.nil? && value.is_a?(Float)

        JsonNumber.fragment(number_text(value))
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
