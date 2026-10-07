module IOStreams
  module Encode
    # Cleanses the data that the encode reader and writer convert, with a built-in rule or a Proc.
    class Cleaner
      # Characters that are not printable, other than line endings.
      NOT_PRINTABLE = /[^[:print:]\r\n]/

      # The built-in rules, by name. Each returns a new string, since the writer can be supplied the caller's string.
      RULES = {
        # Strips all non printable characters
        printable:             ->(data, _) { data.gsub(NOT_PRINTABLE, "") },
        # Replaces non printable characters with the value specified in the `replace` option.
        replace_non_printable: ->(data, replace) { data.gsub(NOT_PRINTABLE, replace || "") }
      }.freeze

      # Parameters
      #   rule: [Symbol|Proc]
      #     The name of a built-in rule, `:printable` or `:replace_non_printable`, or a Proc that is called with
      #     the data and the `replace` value, and returns the cleansed data.
      #
      #   replace: [String|nil]
      #     The `replace` value supplied to the rule.
      #
      # Raises [ArgumentError] for an unknown rule name, or a rule that is neither a Symbol nor a Proc.
      def initialize(rule, replace:)
        @rule    = resolve(rule)
        @replace = replace
      end

      # Returns [String] the cleansed data.
      def call(data)
        @rule.call(data, @replace)
      end

      private

      def resolve(rule)
        case rule
        when Symbol
          RULES[rule] || raise(ArgumentError, "Invalid cleansing rule #{rule.inspect}")
        when Proc
          rule
        else
          raise(ArgumentError,
                "Invalid cleaner #{rule.inspect}: supply the name of a built-in rule, such as :printable, or a Proc")
        end
      end
    end
  end
end
