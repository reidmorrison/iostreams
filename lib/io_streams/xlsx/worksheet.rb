# frozen_string_literal: true

module IOStreams
  module Xlsx
    # Reads the rows of a worksheet part, yielding each as an Array of the value of each of its cells, from column A, as
    # the converter returns it for the cell's text, type and style, with nil for each cell that holds no value, up to its
    # last cell, as v2 read them with the creek gem, so that rows read as before:
    # * An empty row, and a row whose cells hold no value, such as cells that only have a style, is an empty Array.
    # * A row that the worksheet leaves out, since it is empty, is not yielded.
    # * A cell without a reference, which some writers leave out, is in the column after the cell before it.
    #
    # The text of a cell is that of its value, `<v>`, or of its inline string, `<is>`, whose text is that of its `<t>`
    # elements, joined, without that of a phonetic run, `<rPh>`, see `IOStreams::Xlsx::SharedStrings`. The text of a
    # string cell, of type `str` or `inlineStr`, has the characters that Excel escapes decoded, see
    # `IOStreams::Xlsx::Text`, while that of a shared string, of type `s`, is its index.
    class Worksheet
      # Cell types whose text is a string, rather than a number, a boolean, an error or an index.
      STRING_TYPES = %w[str inlineStr].freeze

      # The value of `A`, from which a column's letters count.
      A = "A".ord - 1

      # The index of Excel's last column, XFD, after which a cell reference is not one of a worksheet.
      LAST_COLUMN = 16_383

      # Parameters:
      #   converter: [#call]
      #     Returns the value of a cell, for its text, its type, its `t` attribute, or nil, and the index of its style,
      #     its `s` attribute, or 0.
      #   block:
      #     Receives each row.
      def initialize(converter, &block)
        @converter = converter
        @block     = block
        @row       = nil
        @cell      = false
        @inline    = false
        @phonetic  = 0
        @value     = nil
        @in_value  = false
        @in_text   = false
      end

      def start_element(name, attributes)
        case name
        when "row"
          @row    = []
          @width  = 0
          @column = 0
          @values = false
        when "c"
          return unless @row

          reference = attributes["r"]
          @column   = column(reference) if reference
          @type     = attributes["t"]
          @style    = attributes["s"].to_i
          @cell     = true
          @value    = nil
        when "v"
          @value    = +"" if @cell
          @in_value = @cell
        when "is"
          @inline = @cell
        when "t"
          @value ||= +"" if @inline && @phonetic.zero?
          @in_text = @inline && @phonetic.zero?
        when "rPh"
          @phonetic += 1
        end
      end

      def end_element(name)
        case name
        when "c" then end_cell
        when "row" then end_row
        when "is" then @inline = false
        when "t" then @in_text = false
        when "rPh" then @phonetic -= 1
        when "v" then @in_value = false
        end
      end

      def text(text)
        @value << text if @in_value || @in_text
      end

      private

      def end_cell
        return unless @cell

        unless @value.nil?
          text = STRING_TYPES.include?(@type) ? Text.decode(@value) : @value
          @row[@column] = @converter.call(text, @type, @style)
          @values = true
        end
        @column += 1
        @width   = @column if @column > @width
        @cell    = false
        @value   = nil
      end

      def end_row
        return unless @row

        row = @values ? @row.fill(nil, @row.size...@width) : []
        @row = nil
        @block.call(row)
      end

      # Returns [Integer] the index of the column of a cell reference, such as 27 for `AB1`, or the next column for a
      # reference without letters. Its letters are compared without case, as Excel reads them.
      #
      # Raises [IOStreams::Xlsx::XmlScanner::Invalid] for a column after Excel's last, rather than hold a row of that
      # many cells.
      def column(reference)
        index = 0
        reference.each_byte do |byte|
          byte -= 32 if byte.between?(97, 122)
          break unless byte.between?(65, 90)

          index = (index * 26) + byte - A
          next unless index > LAST_COLUMN + 1

          raise(XmlScanner::Invalid, "the cell reference #{reference.inspect}, after Excel's last column, XFD")
        end
        index.zero? ? @column : index - 1
      end
    end
  end
end
