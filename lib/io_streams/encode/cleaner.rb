# frozen_string_literal: true

module IOStreams
  module Encode
    # Cleanses the data that the encode reader and writer convert, with a built-in rule or a Proc.
    class Cleaner
      # Characters that are not printable, other than line endings.
      NOT_PRINTABLE = /[^[:print:]\r\n]/

      # The built-in rules, by name. Each leaves the data supplied to it as it is, since the writer can be supplied the
      # caller's string, and returns it when it has nothing to cleanse, rather than a copy of it.
      RULES = {
        # Strips all non printable characters
        printable:             ->(data, _) { data.match?(NOT_PRINTABLE) ? data.gsub(NOT_PRINTABLE, "") : data },
        # Replaces non printable characters with the value specified in the `replace` option.
        replace_non_printable: lambda do |data, replace|
          data.match?(NOT_PRINTABLE) ? data.gsub(NOT_PRINTABLE, replace || "") : data
        end
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
        @built_in = rule.is_a?(Symbol)
        @rule     = resolve(rule)
        @replace  = replace
      end

      # Returns [String] the cleansed data.
      #
      # Parameters
      #   shared: [true|false]
      #     Whether the data belongs to the caller, such as a line that it wrote, so that it must not be changed: a Proc,
      #     which could change it, is then called with a copy of it, whereas a built-in rule never changes it.
      #     Default: false
      def call(data, shared: false)
        @rule.call(shared && !@built_in ? data.dup : data, @replace)
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
