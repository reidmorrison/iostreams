# frozen_string_literal: true

module IOStreams
  module Xlsx
    # Reads the shared strings of a workbook, `xl/sharedStrings.xml` as Excel names it: the text of each string item,
    # `<si>`, which is that of its `<t>` elements, whether plain or in the runs of rich text, `<r>`, joined, without the
    # text of a phonetic run, `<rPh>`, which only guides reading East Asian text, and with the characters that Excel
    # escapes decoded, see `IOStreams::Xlsx::Text.decode`.
    class SharedStrings
      # Returns [Array<String>] the text of each string item, by its index.
      attr_reader :strings

      def initialize
        @strings  = []
        @item     = nil
        @text     = false
        @phonetic = 0
      end

      def start_element(name, _attributes)
        case name
        when "si" then @item = +""
        when "t" then @text = @item && @phonetic.zero?
        when "rPh" then @phonetic += 1
        end
      end

      def end_element(name)
        case name
        when "si"
          @strings << Text.decode(@item) if @item
          @item = nil
          @text = false
        when "t" then @text = false
        when "rPh" then @phonetic -= 1 if @phonetic.positive?
        end
      end

      def text(text)
        @item << text if @text && @item
      end
    end
  end
end
