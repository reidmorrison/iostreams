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
    #     The values that a value of the field must be one of, of any type. A field of type `any` compares the value as
    #     it is read, so the text "1" of CSV is not the number 1.
    #
    #   minimum, maximum: [Object]
    #     The least and the greatest value of the field, of an integer, number, date, time, datetime or duration field.
    #     A time compares as the instant that it is on 2000-01-01, so a maximum of "17:00:00" accepts 18:00:00+02:00.
    #
    #   exclusiveMinimum, exclusiveMaximum: [Object]
    #     A value that each value of the field must be greater than, or less than, of the same types as `minimum`.
    #
    #   minLength, maxLength: [Integer]
    #     The fewest and the most characters of a string, or items of an array or an object.
    #
    #   pattern: [String]
    #     A Ruby regular expression that the whole text of a string must match, as if it were wrapped in
    #     `\A(?:...)\z`, whose classes, such as `\w`, `\d` and `\b`, are those of Unicode, as in XML Schema, so that `\w+`
    #     matches `café`. Frictionless writes the pattern in the syntax of XML Schema, which matches the whole value too,
    #     and whose patterns are mostly those of Ruby, apart from its own classes, such as `\i` and `\c`, and its
    #     subtraction of classes, such as `[a-z-[aeiou]]`, which Ruby does not have.
    #
    # Each value of a constraint, such as `minimum: "2026-01-01"` of a date, is read by the field, see
    # `IOStreams::Schema::Field#constraint_value`, as its values are, and raises ArgumentError when it is not one, or when
    # the bounds leave no value, such as a `minimum` more than the `maximum`, or a bound is NaN. A value checked is the
    # value that the field read, such as a number rounded to its `decimals`. A missing value is not checked, apart from
    # by `required`.
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
      ORDERED_TYPES = %w[integer number date time datetime duration].freeze

      # The types whose values have a length, `minLength` and `maxLength`.
      LENGTH_TYPES = %w[string array object].freeze

      # The types whose values `enum` and `categories` hold as the keys of a Hash, since `eql?` and `hash` of their
      # values agree with `==`, so that each value is found at once, while any other type compares with `==`, such as
      # the BigDecimal 1 of a number and its Float 1.0.
      KEYED_TYPES = %w[string integer].freeze

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

      # The lower and the upper bounds that leave no value between them when the lower one is more than the upper one,
      # or not less than it, see #check_range.
      RANGES = [
        ["minimum", "maximum", :>],
        ["minimum", "exclusiveMaximum", :>=],
        ["exclusiveMinimum", "maximum", :>=],
        ["exclusiveMinimum", "exclusiveMaximum", :>=]
      ].freeze

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
      # The field must be able to read the values of constraints, see `IOStreams::Schema::Field#constraint_value`, so it
      # builds its constraints last.
      #
      # Raises ArgumentError for constraints that are not supported, or are not valid, for `allow_blank` when the field is
      # not required, whose values can be blank anyway, and for an `enum` value that is not one of the categories.
      def initialize(constraints, field, allow_blank: false, categories: nil)
        @field       = field
        @name        = field.name
        @keyed       = KEYED_TYPES.include?(field.type)
        constraints  = check_hash(constraints)
        @required    = check_required(constraints["required"])
        @allow_blank = check_allow_blank(allow_blank)
        @enum        = read_enum(constraints)
        @bounds      = read_bounds(constraints)
        @min_length  = check_length("minLength", constraints["minLength"])
        @max_length  = check_length("maxLength", constraints["maxLength"])
        @pattern     = read_pattern(constraints["pattern"])
        check_categories(categories)
        @categories  = values_of(categories)
        @enum_values = nil
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
        violated(read, "is not one of its enum values") if @enum && !member?(@enum, value)
        violated(read, "is not one of its categories") if @categories && !member?(@categories, value)
        @bounds.each do |operator, bound, problem, property, text|
          next if in_bound?(value, operator, bound)

          violated(read, nan?(value) ? "cannot be compared with its #{property}, #{text}" : "is #{problem}, #{text}")
        end
        check_lengths(value, read) if @min_length || @max_length
        check_pattern(value, read) if @pattern
        value
      end

      private

      # Returns [true|false] whether the value is one of the values, a Hash of them for a type whose values are its keys,
      # see KEYED_TYPES, otherwise an Array.
      def member?(values, value)
        values.is_a?(::Hash) ? values.key?(value) : values.include?(value)
      end

      # Returns [Hash|Array|nil] the values of `enum` or `categories`, held as #member? finds them.
      def values_of(values)
        return if values.nil?

        (@keyed ? values.to_h { |value| [value, true] } : values).freeze
      end

      # Returns [true|false] whether the value is within the bound, false for one that cannot be compared with it, such
      # as NaN, which is neither more nor less than any number.
      def in_bound?(value, operator, bound)
        result =
          case operator
          when :>= then value >= bound
          when :<= then value <= bound
          when :> then value > bound
          else value < bound
          end
        result == true
      rescue ArgumentError, NoMethodError
        false
      end

      # Returns [true|false] whether the value is NaN, which cannot be compared with a bound.
      def nan?(value)
        value.respond_to?(:nan?) && value.nan?
      end

      # Raises `IOStreams::Errors::InvalidValue` when the text does not match the pattern, also when it cannot be
      # compared with it, such as text that is not valid in its encoding.
      def check_pattern(value, read)
        return if @pattern.match?(value)

        violated(read, "does not match its pattern, /#{@pattern_text}/")
      rescue ArgumentError, EncodingError => e
        violated(read, "cannot be matched with its pattern, /#{@pattern_text}/: #{e.message}")
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

      # Returns [Hash|Array|nil] the values of `enum`, read by the field, held as #member? finds them.
      def read_enum(constraints)
        return unless constraints.key?("enum")

        enum = constraints["enum"]
        unless enum.is_a?(Array) && !enum.empty?
          raise(ArgumentError, "Field #{@name.inspect}: constraints enum must be an Array of values: #{enum.inspect}")
        end

        @enum_values = enum.map { |value| constraint_value("enum", value) }
        values_of(@enum_values)
      end

      # Returns [Array<Array>] each of `minimum`, `maximum`, `exclusiveMinimum` and `exclusiveMaximum` that the constraints
      # have: the comparison of a value with it, its value read by the field, how a message says that a value is outside
      # it, its name, and its text as it was given, for the message of an error.
      #
      # Raises ArgumentError for a bound that is NaN, which no value can be compared with, and for bounds that leave no
      # value, see #check_range.
      def read_bounds(constraints)
        values = {}
        bounds = BOUNDS.filter_map do |property, (operator, problem)|
          next unless constraints.key?(property)

          text  = constraints[property]
          bound = constraint_value(property, text)
          if nan?(bound)
            raise(ArgumentError, "Field #{@name.inspect}: constraints #{property} cannot be NaN, which no value can be " \
                                 "compared with")
          end
          values[property] = bound
          [operator, bound, problem, property, text.inspect].freeze
        end
        check_range(values, constraints)
        bounds.freeze
      end

      # Raises ArgumentError for a lower bound that leaves no value below the upper bound, such as a `minimum` of 10 and a
      # `maximum` of 5, see RANGES.
      def check_range(values, constraints)
        RANGES.each do |lower, upper, operator|
          next unless values.key?(lower) && values.key?(upper)
          next unless in_bound?(values[lower], operator, values[upper])

          raise(ArgumentError, "Field #{@name.inspect}: constraints #{lower}, #{constraints[lower].inspect}, leaves no " \
                               "value up to its #{upper}, #{constraints[upper].inspect}")
        end
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
        # Compiled alone first, so that a pattern that closes a group that it did not open, such as "a)|(b", raises
        # rather than change what the anchors around it hold.
        Regexp.new(pattern)
        Regexp.new("\\A(?u:#{pattern})\\z")
      rescue RegexpError => e
        raise(ArgumentError, "Field #{@name.inspect}: constraints pattern is not a valid regular expression: #{e.message}")
      end

      # Raises ArgumentError for a value of `enum` that is not one of the categories, since no value could be both.
      def check_categories(categories)
        return if categories.nil? || @enum_values.nil?

        other = @enum_values.find { |value| !categories.include?(value) }
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
