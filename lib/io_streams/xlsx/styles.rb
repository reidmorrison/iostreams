# frozen_string_literal: true

module IOStreams
  module Xlsx
    # Reads the number formats of the styles of a workbook, `xl/styles.xml` as Excel names it: the code of each custom
    # number format, `<numFmts>`, and the number format of each cell style, `<cellXfs>`, by the index of the style, as a
    # cell names it with its `s` attribute. Which of them are dates or times is for `IOStreams::Xlsx::Cells` to say.
    class Styles
      # Returns [Hash<Integer, String>] the code of each custom number format, by its id.
      attr_reader :format_codes

      # Returns [Array<Integer|nil>] the id of the number format of each cell style, by its index, or nil for a style
      # without one.
      attr_reader :format_ids

      def initialize
        @format_codes = {}
        @format_ids   = []
        @within       = nil
      end

      def start_element(name, attributes)
        case name
        when "numFmts", "cellXfs" then @within = name
        when "numFmt"
          @format_codes[attributes["numFmtId"].to_i] = attributes["formatCode"].to_s if @within == "numFmts"
        when "xf"
          @format_ids << attributes["numFmtId"]&.to_i if @within == "cellXfs"
        end
      end

      def end_element(name)
        @within = nil if name == @within
      end

      def text(_text)
      end
    end
  end
end
