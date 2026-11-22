# frozen_string_literal: true

module IOStreams
  module Xlsx
    # The text of a cell as a workbook holds it, in which Excel escapes a character that XML cannot hold, such as a
    # control character, as `_xHHHH_`, its code in hex, such as `_x000D_` for a CR, and an `_` that starts such text as
    # `_x005F_`, so that `_x005F_x000D_` is the text `_x000D_`.
    module Text
      ESCAPE = /_x(\h{4})_/

      # What #encode escapes: the markup of XML, a CR, which XML would read as a line feed, a character that XML 1.0
      # cannot hold, such as a control character, and an `_` that starts text that reads as an escape.
      SPECIAL = /[&<>\r]|_(?=x\h{4}_)|[^\t\n\u0020-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/

      # The escape of each special character that has one of its own, see SPECIAL. Any other is `_xHHHH_`.
      REPLACEMENTS = {"&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "_" => "_x005F_"}.freeze

      # Whitespace at either end of text, which a spreadsheet application may remove unless the element of the text
      # says to preserve it.
      EDGE_SPACE = /\A\s|\s\z/

      # The characters outside the Basic Multilingual Plane, each two code units of UTF-16, see .length.
      SUPPLEMENTARY = "\u{10000}-\u{10FFFF}"

      # Returns [String] the element of XML that holds the text of a cell, `<t>`, of text that .encode escaped, saying
      # to preserve its whitespace when it starts or ends with any.
      def self.element(text)
        text.match?(EDGE_SPACE) ? %(<t xml:space="preserve">#{text}</t>) : "<t>#{text}</t>"
      end

      # Returns [String] the text in UTF-8, see .utf8, escaped as XML holds it, and as Excel escapes it, see the module,
      # which .decode reads back: the inverse of .decode and of reading the XML.
      #
      # Raises [IOStreams::Errors::InvalidEncoding] for text that UTF-8 cannot hold, see .utf8.
      def self.encode(text)
        text = utf8(text)
        return text unless text.match?(SPECIAL)

        text.gsub(SPECIAL) { |char| REPLACEMENTS[char] || format("_x%04X_", char.ord) }
      end

      # Returns [String] the text as UTF-8, as a workbook holds it, see `IOStreams::Encode.utf8`.
      #
      # Raises [IOStreams::Errors::InvalidEncoding] for text that UTF-8 cannot hold, starting with where the text is.
      def self.utf8(text, place: "the text of a cell")
        IOStreams::Encode.utf8(text, place: place)
      end

      # Returns [Integer] the length of text in UTF-8 as Excel counts it, in UTF-16 code units, so that a character
      # outside the Basic Multilingual Plane, such as an emoji, counts as two, as Excel counts it against its limits of
      # the text of a cell and the name of a worksheet.
      def self.length(text)
        text.length + text.count(SUPPLEMENTARY)
      end

      # Returns [String] the text with the characters that Excel escapes decoded, keeping an escape of a code that is not
      # a character, such as half of a surrogate pair, as it is.
      def self.decode(text)
        return text unless text.include?("_x")

        text.gsub(ESCAPE) do |match|
          Regexp.last_match(1).to_i(16).chr(Encoding::UTF_8)
        rescue RangeError
          match
        end
      end
    end
  end
end
