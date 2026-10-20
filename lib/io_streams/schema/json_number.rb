# frozen_string_literal: true

require "json"

module IOStreams
  class Schema
    # The text of a number, which JSON writes as it is, rather than through a Float, so that a BigDecimal keeps all of
    # its digits, such as `12345678901234567.89`, and the digits after the decimal point that its field writes, such as
    # `12.50`, see `IOStreams::Schema::Field#render`.
    #
    # The json gem writes the text that #to_json returns. It is a Numeric, whose #as_json is itself, so that
    # ActiveSupport, which replaces how Ruby writes JSON, writes it as a number too: its encoder keeps a Numeric that
    # #as_json returns, and then has the json gem write it.
    class JsonNumber < Numeric
      # Returns [JSON::Fragment|IOStreams::Schema::JsonNumber] the text of the number in the form that the json gem
      # writes as it is: a `JSON::Fragment` from json 2.10, which its coder writes without calling back into Ruby,
      # see `IOStreams::Tabular::Parser::Json`, otherwise an `IOStreams::Schema::JsonNumber`.
      def self.fragment(text)
        defined?(::JSON::Fragment) ? ::JSON::Fragment.new(text) : new(text)
      end

      # Returns [String] the text of the number.
      attr_reader :text

      def initialize(text)
        super()
        @text = text
        freeze
      end

      # Returns [String] the number as JSON.
      def to_json(*)
        text
      end

      # Returns [IOStreams::Schema::JsonNumber] itself, a number, which ActiveSupport writes with #to_json.
      def as_json(*)
        self
      end

      # Returns [String] the text of the number.
      def to_s
        text
      end

      def ==(other)
        other.is_a?(JsonNumber) && other.text == text
      end
      alias eql? ==

      def hash
        text.hash
      end
    end
  end
end
