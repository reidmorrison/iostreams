# frozen_string_literal: true

module IOStreams
  class Schema
    # The constraints of a field, as Frictionless defines them, see https://datapackage.org/standard/table-schema/:
    # the rules that its values must follow, which it checks once its field has converted a value to its type, both
    # when reading and when writing, see `IOStreams::Schema::Field#cast`.
    #
    # Constraints:
    #   required: [true|false]
    #     Whether the field must have a value: a value that is nil, or a missing value, such as empty text, raises
    #     `IOStreams::Errors::InvalidValue`, see #no_value, unless the field allows blank values, see `allowBlank` in
    #     `IOStreams::Schema::Field`. A header row or record without the field raises `IOStreams::Errors::InvalidHeader`,
    #     see `IOStreams::Schema#check_columns`, whether or not it allows blank values, apart from a JSON record read
    #     through a contract alone, whose missing key is a value of nil, see `IOStreams::Schema::Columns.new(keys_vary:)`.
    #     Default: false
    #
    #   enum: [Array]
    #     The values that a value of the field must be one of, of any type.
    #
    #   minimum, maximum: [Object]
    #     The least and the greatest value of the field, of an integer, number, date, time, datetime, duration, year or
    #     yearmonth field.
    #
    #   exclusiveMinimum, exclusiveMaximum: [Object]
    #     A value that each value of the field must be greater than, or less than, of the same types as `minimum`.
    #
    #   minLength, maxLength: [Integer]
    #     The fewest and the most characters of a string, or items of a list, an array or an object.
    #
    #   pattern: [String]
    #     A Ruby regular expression that the whole text of a string must match, as if it were wrapped in
    #     `\A(?:...)\z`. Frictionless writes the pattern in the syntax of XML Schema, which matches the whole value
    #     too, and whose patterns are mostly those of Ruby, apart from its own classes, such as `\i` and `\c`, and its
    #     subtraction of classes, such as `[a-z-[aeiou]]`, which Ruby does not have.
    #
    # Each value of a constraint, such as `minimum: "2026-01-01"` of a date, is read by the field, see
    # `IOStreams::Schema::Field#constraint_value`, as its values are, and raises ArgumentError when it is not one.
    #
    # A field also gives its `categories`, the values of a string or integer field, see `IOStreams::Schema::Field`,
    # which a value must be one of, as for `enum`, whose values must be among them.
    #
    # `unique` and `jsonSchema` are not supported yet, so they raise ArgumentError, rather than appear to check values
    # that they do not.
    class Constraints
      # The constraints of Frictionless that IOStreams does not support yet.
      UNSUPPORTED = %w[unique jsonSchema].freeze

      # The types whose values `minimum`, `maximum`, `exclusiveMinimum` and `exclusiveMaximum` compare.
      ORDERED_TYPES = %w[integer number date time datetime duration year yearmonth].freeze

      # The types whose values have a length, `minLength` and `maxLength`.
      LENGTH_TYPES = %w[string list array object].freeze

      # The types of each constraint other than `required` and `enum`, which apply to every type.
      TYPES = {
        "minimum"          => ORDERED_TYPES,
        "maximum"          => ORDERED_TYPES,
        "exclusiveMinimum" => ORDERED_TYPES,
        "exclusiveMaximum" => ORDERED_TYPES,
        "minLength"        => LENGTH_TYPES,
        "maxLength"        => LENGTH_TYPES,
        "pattern"          => %w[string]
      }.freeze

      # The constraints that IOStreams supports.
      SUPPORTED = (%w[required enum] + TYPES.keys).freeze

      # The comparison of a value with each bound, and how its message says that a value is outside it.
      BOUNDS = {
        "minimum"          => [:>=, "less than its minimum"],
        "maximum"          => [:<=, "more than its maximum"],
        "exclusiveMinimum" => [:>, "not more than its exclusiveMinimum"],
        "exclusiveMaximum" => [:<, "not less than its exclusiveMaximum"]
      }.freeze

      # Parameters:
      #   constraints: [Hash|nil]
      #     The constraints, see above, whose keys are Strings or Symbols.
      #
      #   field: [IOStreams::Schema::Field]
      #     The field, which names its errors, and reads the values of the constraints, see
      #     `IOStreams::Schema::Field#constraint_value`.
      #
      #   allow_blank: [true|false]
      #     Whether a required field can have no value, see `allowBlank` in `IOStreams::Schema::Field`.
      #     Default: false
      #
      #   categories: [Array|nil]
      #     The values of the field read from its `categories`, which a value must be one of, see
      #     `IOStreams::Schema::Field`.
      #     Default: none
      #
      # Raises ArgumentError for constraints that are not supported, or are not valid, for `allow_blank` when the field is
      # not required, whose values can be blank anyway, and for an `enum` value that is not one of the categories.
      def initialize(constraints, field, allow_blank: false, categories: nil)
        @field       = field
        @name        = field.name
        constraints  = check_hash(constraints)
        @required    = check_required(constraints["required"])
        @allow_blank = check_allow_blank(allow_blank)
        @enum        = read_enum(constraints)
        @bounds      = read_bounds(constraints)
        @min_length  = check_length("minLength", constraints["minLength"])
        @max_length  = check_length("maxLength", constraints["maxLength"])
        @pattern     = read_pattern(constraints["pattern"])
        @categories  = categories
        check_categories
        @checks = !(@enum.nil? && @bounds.empty? && @min_length.nil? && @max_length.nil? && @pattern.nil? && @categories.nil?)
        @field  = nil
        freeze
      end

      # Returns [true|false] whether the header row, or each record, must have the field, see `required` above, and,
      # unless it allows blank values, a value, see #value_required?.
      def required?
        @required
      end

      # Returns [true|false] whether each value of the field must be present: when it is required, see `required`
      # above, unless it allows blank values, so that a value of nil, or a missing value, raises, see #no_value.
      def value_required?
        @required && !@allow_blank
      end

      # Returns [true|false] whether any constraint checks the values of the field, see #check, so that a field that has
      # none does not ask.
      def checks?
        @checks
      end

      # Returns nil, the value of a field that has none, unless each value of the field must be present, see
      # #value_required?, which raises `IOStreams::Errors::InvalidValue`, holding the value as it was read, such as nil or
      # empty text, see `IOStreams::Errors::InvalidValue#value`.
      def no_value(value = nil)
        return unless value_required?

        message = "Field #{@name.inspect} is required, but has no value"
        raise(IOStreams::Errors::InvalidValue.new(message, field: @name, value: value))
      end

      # Returns the value of the field, converted to its type, once it follows every constraint, see above.
      #
      # Raises `IOStreams::Errors::InvalidValue` for the first constraint that it does not follow, naming the value as
      # it was read.
      def check(value, read = value)
        violated(read, "is not one of its enum values") if @enum && !@enum.include?(value)
        violated(read, "is not one of its categories") if @categories && !@categories.include?(value)
        @bounds.each do |property, (bound, descriptor)|
          operator, problem = BOUNDS.fetch(property)
          violated(read, "is #{problem}, #{descriptor.inspect}") unless in_bound?(value, operator, bound)
        end
        check_lengths(value, read) if @min_length || @max_length
        violated(read, "does not match its pattern, /#{@pattern_text}/") if @pattern && !@pattern.match?(value)
        value
      end

      private

      # Returns [true|false] whether the value is within the bound, false for one that cannot be compared with it, such
      # as NaN, which is neither more nor less than any number.
      def in_bound?(value, operator, bound)
        value.public_send(operator, bound) == true
      rescue ArgumentError, NoMethodError
        false
      end

      def check_lengths(value, read)
        length = value.size
        if @min_length && length < @min_length
          violated(read, "has a length of #{length}, less than its minLength, #{@min_length}")
        end
        return unless @max_length && length > @max_length

        violated(read, "has a length of #{length}, more than its maxLength, #{@max_length}")
      end

      def violated(value, problem)
        text = value.inspect
        text = "#{text[0, 60]}..." if text.length > 63
        raise(IOStreams::Errors::InvalidValue.new("Field #{@name.inspect}: #{text} #{problem}", field: @name, value: value))
      end

      # Returns [Hash] the constraints with String keys.
      #
      # Raises ArgumentError for a constraint that is not supported, or that does not apply to the type of the field.
      def check_hash(constraints)
        return {} if constraints.nil?
        unless constraints.is_a?(Hash)
          raise(ArgumentError, "Field #{@name.inspect}: constraints must be a Hash: #{constraints.inspect}")
        end

        constraints = constraints.transform_keys(&:to_s)
        constraints.each_key do |constraint|
          raise(ArgumentError, "Field #{@name.inspect}: #{problem(constraint)}") unless SUPPORTED.include?(constraint)

          types = TYPES[constraint]
          next if types.nil? || types.include?(@field.type)

          raise(ArgumentError, "Field #{@name.inspect}: the constraint #{constraint.inspect} only applies to a field of " \
                               "type #{[types[0..-2].join(', '), types.last].reject(&:empty?).join(' or ')}, not " \
                               "#{@field.type}")
        end
        constraints
      end

      # Returns [true|false] whether the field is required.
      def check_required(required)
        return false if required.nil?
        return required if [true, false].include?(required)

        raise(ArgumentError, "Field #{@name.inspect}: constraints required must be true or false: #{required.inspect}")
      end

      # Returns [true|false] whether the field allows blank values, which only a required field can.
      def check_allow_blank(allow_blank)
        return allow_blank if !allow_blank || @required

        raise(ArgumentError, "Field #{@name.inspect}: allowBlank only applies to a field whose constraints are required, " \
                             "since the values of any other field can be blank")
      end

      # Returns [Array|nil] the values of `enum`, read by the field.
      def read_enum(constraints)
        return unless constraints.key?("enum")

        enum = constraints["enum"]
        unless enum.is_a?(Array) && !enum.empty?
          raise(ArgumentError, "Field #{@name.inspect}: constraints enum must be an Array of values: #{enum.inspect}")
        end

        enum.map { |value| constraint_value("enum", value) }.freeze
      end

      # Returns [Hash] each of `minimum`, `maximum`, `exclusiveMinimum` and `exclusiveMaximum` that the constraints have,
      # with its value read by the field, and as it was given, for the message of an error.
      def read_bounds(constraints)
        BOUNDS.each_key.with_object({}) do |property, bounds|
          next unless constraints.key?(property)

          descriptor = constraints[property]
          bounds[property] = [constraint_value(property, descriptor), descriptor].freeze
        end.freeze
      end

      # Returns [Object] the value of a constraint, read by the field, see `IOStreams::Schema::Field#constraint_value`.
      #
      # Raises ArgumentError when it is not a value of the field.
      def constraint_value(property, value)
        result = @field.constraint_value(value)
        return result unless result.nil?

        raise(ArgumentError, "Field #{@name.inspect}: constraints #{property} must be a value of the field: #{value.inspect}")
      rescue IOStreams::Errors::InvalidValue => e
        raise(ArgumentError, "Field #{@name.inspect}: constraints #{property} must be a value of the field: #{e.message}")
      end

      def check_length(property, length)
        return if length.nil?
        return length if length.is_a?(Integer) && !length.negative?

        raise(ArgumentError,
              "Field #{@name.inspect}: constraints #{property} must be an Integer of 0 or more: #{length.inspect}")
      end

      # Returns [Regexp|nil] the pattern, matched against the whole text, see `pattern` above.
      def read_pattern(pattern)
        return if pattern.nil?
        unless pattern.is_a?(String)
          raise(ArgumentError, "Field #{@name.inspect}: constraints pattern must be the text of a regular expression: " \
                               "#{pattern.inspect}")
        end

        @pattern_text = pattern
        Regexp.new("\\A(?:#{pattern})\\z")
      rescue RegexpError => e
        raise(ArgumentError, "Field #{@name.inspect}: constraints pattern is not a valid regular expression: #{e.message}")
      end

      # Raises ArgumentError for a value of `enum` that is not one of the categories, since no value could be both.
      def check_categories
        return if @categories.nil? || @enum.nil?

        other = @enum.find { |value| !@categories.include?(value) }
        return if other.nil?

        raise(ArgumentError, "Field #{@name.inspect}: the enum value #{other.inspect} is not one of its categories")
      end

      # Returns [String] why a constraint that IOStreams does not support raises.
      def problem(constraint)
        return "the constraint #{constraint.inspect} is not supported" if UNSUPPORTED.include?(constraint)

        "unknown constraint #{constraint.inspect}"
      end
    end
  end
end
