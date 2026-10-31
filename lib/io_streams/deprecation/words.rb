# frozen_string_literal: true

module IOStreams
  module Deprecation
    # The words of the message of a deprecation warning that depend on how many things it is about, such as the options
    # that are deprecated, so that each message says "is" and "it" of one, and "are" and "them" of more, see .warn.
    class Words
      # Parameters:
      #   items: [Array]
      #     The things that the message is about, such as the names of options.
      def initialize(items)
        @items = items
      end

      # Returns [String] the items as the keywords that a caller supplies them as, such as `compress:, level:`, and an
      # item that is not a Symbol, which is not a keyword, as it is written, such as `"acl"`.
      def keywords
        @items.map { |item| item.is_a?(Symbol) ? "#{item}:" : item.inspect }.join(", ")
      end

      # Returns [true|false] whether the message is about one item.
      def one?
        @items.size == 1
      end

      # Returns [String] "are", or "is" of one item.
      def are
        one? ? "is" : "are"
      end

      # Returns [String] "them", or "it" of one item.
      def them
        one? ? "it" : "them"
      end

      # Returns [String] "they are", or "it is" of one item.
      def they_are
        one? ? "it is" : "they are"
      end
    end
  end
end
