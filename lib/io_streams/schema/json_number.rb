# frozen_string_literal: true

module IOStreams
  class Schema
    # A number that JSON writes as its text, rather than as a Float, so that a BigDecimal keeps all of its digits,
    # such as `12345678901234567.89`, and the digits after the decimal point that its field writes, such as `12.50`.
    #
    # The json gem writes the text that #to_json returns as it is, see `IOStreams::Tabular::Parser::Json`.
    class JsonNumber
      # Returns [IOStreams::Schema::JsonNumber|Float] the number as JSON writes it: a BigDecimal as the text that the
      # block returns, so that it keeps all of its digits, and a Float, or a number that is not finite, which JSON
      # cannot hold, as a Float, rounded to the decimals when they are supplied.
      def self.of(number, decimals)
        return new(yield) unless number.is_a?(Float) || !number.finite?

        (decimals ? number.round(decimals) : number).to_f
      end

      # Returns [String] the text of the number.
      attr_reader :text

      def initialize(text)
        @text = text
        freeze
      end

      # Returns [String] the number as JSON.
      def to_json(*)
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
