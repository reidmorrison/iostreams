# frozen_string_literal: true

module IOStreams
  class Schema
    # The constraints of a field, as Frictionless defines them, see https://datapackage.org/standard/table-schema/:
    # the rules that its values must follow.
    #
    # Constraints:
    #   required: [true|false]
    #     Whether the field must have a value: a value that is nil, or empty text, raises
    #     `IOStreams::Errors::InvalidValue`, see #no_value, unless the field allows blank values, see `allowBlank` in
    #     `IOStreams::Schema::Field`. A header row or record without the field raises `IOStreams::Errors::InvalidHeader`,
    #     see `IOStreams::Schema#check_columns`, whether or not it allows blank values.
    #     Default: false
    #
    # The other constraints of Frictionless, such as `maxLength`, are not supported yet, so they raise ArgumentError,
    # rather than appear to check values that they do not.
    class Constraints
      # The constraints of Frictionless that IOStreams does not support yet.
      UNSUPPORTED = %w[unique minLength maxLength minimum maximum exclusiveMinimum exclusiveMaximum jsonSchema pattern
                       enum].freeze

      # Parameters:
      #   constraints: [Hash|nil]
      #     The constraints, see above, whose keys are Strings or Symbols.
      #
      #   name: [String|Symbol]
      #     The name of the field, for the messages of its errors.
      #
      #   allow_blank: [true|false]
      #     Whether a required field can have no value, see `allowBlank` in `IOStreams::Schema::Field`.
      #     Default: false
      #
      # Raises ArgumentError for constraints that are not supported, or are not valid, and for `allow_blank` when the
      # field is not required, whose values can be blank anyway.
      def initialize(constraints, name, allow_blank: false)
        @name        = name
        @required    = check(constraints)
        @allow_blank = check_allow_blank(allow_blank)
        freeze
      end

      # Returns [true|false] whether the header row, or each record, must have the field, see `required` above, and,
      # unless it allows blank values, a value.
      def required?
        @required
      end

      # Returns nil, the value of a field that has none, unless it is required, and does not allow blank values, which
      # raises `IOStreams::Errors::InvalidValue`.
      def no_value
        return unless @required && !@allow_blank

        raise(IOStreams::Errors::InvalidValue, "Field #{@name.inspect} is required, but has no value")
      end

      # Returns [String] the empty text of a field whose type keeps it as its value, such as a string, unless the field is
      # required, which raises `IOStreams::Errors::InvalidValue`, since Frictionless treats empty text as no value.
      def no_text(text)
        no_value
        text
      end

      private

      # Returns [true|false] whether the field is required, the only constraint that IOStreams supports yet.
      def check(constraints)
        return false if constraints.nil?
        unless constraints.is_a?(Hash)
          raise(ArgumentError, "Field #{@name.inspect}: constraints must be a Hash: #{constraints.inspect}")
        end

        constraints = constraints.transform_keys(&:to_s)
        other       = (constraints.keys - ["required"]).first
        raise(ArgumentError, "Field #{@name.inspect}: #{problem(other)}") if other

        required = constraints["required"]
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

      # Returns [String] why a constraint other than `required` raises.
      def problem(constraint)
        return "the constraint #{constraint.inspect} is not supported" if UNSUPPORTED.include?(constraint)

        "unknown constraint #{constraint.inspect}"
      end
    end
  end
end
