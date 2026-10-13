require "date"
require "time"

module IOStreams
  class Schema
    # A field of a schema: its name and type, the text form of its values, and for a fixed width file its position.
    #
    # Properties of a field, as Frictionless defines them:
    #   name: [String|Symbol]
    #     The key of the field in each record. Required.
    #     A fixed width file returns records whose keys are the names as they are given, so a Symbol name returns a
    #     Symbol key. Other formats keep the keys of the file, see `IOStreams::Schema#field`.
    #
    #   type: [String]
    #     "string":   a String.
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
    # and the Frictionless properties that it does not support yet, such as `constraints`, so that a schema never
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
      PROPERTIES = %w[name type format width start].freeze

      # The properties of a field that only describe it to people.
      DESCRIPTIVE_PROPERTIES = %w[title description example rdfType].freeze

      # The properties of a Frictionless field that IOStreams does not support yet.
      UNSUPPORTED_PROPERTIES = %w[constraints missingValues categories categoriesOrdered decimalChar groupChar
                                  bareNumber delimiter itemType].freeze

      DEFAULT_TRUE_VALUES  = %w[true True TRUE 1].freeze
      DEFAULT_FALSE_VALUES = %w[false False FALSE 0].freeze

      # The text of the numbers that are not finite, whose case does not matter.
      SPECIAL_NUMBERS = {"nan" => Float::NAN, "inf" => Float::INFINITY, "-inf" => -Float::INFINITY}.freeze

      INTEGER  = /\A[+-]?\d+\z/
      NUMBER   = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/
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

      # Parameters:
      #   descriptor: [Hash]
      #     The properties of the field, see above, whose keys are Strings or Symbols.
      #
      # Raises ArgumentError when the descriptor is not a valid field.
      def initialize(descriptor)
        raise(ArgumentError, "A schema field must be a Hash: #{descriptor.inspect}") unless descriptor.is_a?(Hash)

        descriptor = descriptor.transform_keys(&:to_s)
        @name      = descriptor["name"]
        unless @name.is_a?(String) || @name.is_a?(Symbol)
          raise(ArgumentError, "A schema field must have a name: #{descriptor.inspect}")
        end

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
        require_bigdecimal if @type == "number" && !@float
        freeze
      end

      # Returns [true|false] whether the values of this field are numbers, which a fixed width file zero fills.
      def numeric?
        %w[integer number].include?(type)
      end

      # Returns [true|false] whether to write only the first `width` characters of a longer string in a fixed width
      # file.
      def truncate?
        @truncate
      end

      # Returns the value converted to the type of this field, such as the Integer `12` for the text `"0012"`, or nil
      # when the value is nil, or is text that is empty once its leading and trailing whitespace is removed, except
      # for a string or any field, which returns the text as it is.
      #
      # Raises `IOStreams::Errors::InvalidValue` when the value is not one of this type.
      def cast(value)
        return if value.nil?
        return value if type == "any"
        return cast_string(value) if type == "string"

        if value.is_a?(String)
          value = value.strip
          return if value.empty?
        end

        send(:"cast_#{type}", value)
      end

      # Returns the value converted to the type of this field, see #cast, in the form that the supplied format of
      # file writes it:
      #   :text   the text of the value, such as "12.50", for a format of text, such as CSV.
      #   :json   the value as JSON represents it: an integer, number or boolean as itself, a number as a Float, and
      #           any other value as its text.
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
        when "date" then @format ? value.strftime(@format) : value.iso8601
        when "datetime" then @format ? value.strftime(@format) : datetime_text(value)
        else value.to_s
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

      def check_values(property, values, default)
        return default if values.nil?
        return values.dup.freeze if values.is_a?(Array) && !values.empty? && values.all?(String)

        raise(ArgumentError, "Field #{name.inspect}: #{property} must be an Array of Strings: #{values.inspect}")
      end

      # The bigdecimal gem is a default gem before Ruby 3.4, and a bundled gem since, so it is loaded only when a
      # number field needs it.
      def require_bigdecimal
        require "bigdecimal"
      rescue LoadError => e
        raise(LoadError, "Field #{name.inspect}: a number field needs the bigdecimal gem, so add `gem \"bigdecimal\"` to " \
                         "the Gemfile, or set `floatNumber: true` to return a Float: #{e.message}")
      end

      def cast_string(value)
        return value if value.is_a?(String)
        return value.to_s("F") if bigdecimal?(value)
        return value.iso8601 if value.is_a?(Date) || value.is_a?(Time)
        return value.to_s if value.is_a?(Symbol) || value.is_a?(Numeric) || [true, false].include?(value)

        invalid(value)
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
        return invalid(value) unless value.is_a?(Integer) || value.is_a?(Float) || bigdecimal?(value)
        return value.to_f if @float

        bigdecimal?(value) ? value : BigDecimal(value.to_s)
      end

      def parse_number(text)
        special = SPECIAL_NUMBERS[text.downcase]
        return @float ? special : BigDecimal(special.to_s) if special
        return invalid(text) unless NUMBER.match?(text)

        @float ? Float(text) : BigDecimal(text)
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

      def cast_datetime(value)
        return value if value.is_a?(Time)
        return value.to_time if value.is_a?(DateTime)
        return invalid(value) unless value.is_a?(String)
        return parse_time(Time, value) if @format
        return invalid(value) unless DATETIME.match?(value)

        Time.iso8601(value)
      rescue ArgumentError
        invalid(value)
      end

      # Returns [Date|Time] the text read with the strptime pattern of the format, which must match all of the text.
      def parse_time(klass, text)
        parts = Date._strptime(text, @format)
        return invalid(text) if parts.nil? || parts.key?(:leftover)

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

      # Returns [String] the time in ISO 8601, with as many digits of its fraction of a second as it needs.
      def datetime_text(value)
        nanoseconds = value.nsec
        digits      =
          if nanoseconds.zero? then 0
          elsif (nanoseconds % 1_000_000).zero? then 3
          elsif (nanoseconds % 1000).zero? then 6
          else 9
          end
        value.iso8601(digits)
      end

      def json(value)
        case type
        when "number" then (@decimals ? value.round(@decimals) : value).to_f
        when "integer", "boolean", "string", "any" then value
        else text(value)
        end
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
