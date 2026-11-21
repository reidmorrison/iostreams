# frozen_string_literal: true

module IOStreams
  module Xlsx
    # The styles of the cells of a workbook that IOStreams writes: the index of the style of each kind of cell that has
    # a number format, which a cell names with its `s` attribute, and the part that holds them, `xl/styles.xml`. A cell
    # holds a date, a date and time, or a time of day as a number, which only its number format says is one, see
    # `IOStreams::Xlsx::Cells`, which reads them back. A number with decimals has a style of its own for each number of
    # decimals, which is added once a cell needs it, such as `0.00` for two.
    class CellStyles
      # A cell of a date, of the custom format `yyyy-mm-dd`.
      DATE = 1

      # A cell of a date and time, of the custom format `yyyy-mm-dd hh:mm:ss`.
      DATE_TIME = 2

      # A cell of a time of day, of Excel's built-in format 21, `h:mm:ss`.
      TIME_OF_DAY = 3

      # The part, by its name within the workbook.
      PART = "xl/styles.xml"

      # The id of the first custom number format, which Excel numbers from 164, and the custom formats of a date and of a
      # date and time, which the styles of a date and a date and time have.
      FIRST_CUSTOM_FORMAT = 164
      FORMATS             = ["yyyy\\-mm\\-dd", "yyyy\\-mm\\-dd hh:mm:ss"].freeze

      # The number formats of the styles, after that of a cell without a format, by their index.
      STYLE_FORMATS = [FIRST_CUSTOM_FORMAT, FIRST_CUSTOM_FORMAT + 1, 21].freeze

      # The most decimals of a number format, which Excel limits to 30.
      MOST_DECIMALS = 30

      def initialize
        @decimals = {}
      end

      # Returns [Integer] the index of the style of a number shown with the number of decimals, such as `0.00` for 2,
      # adding it when it is new. More than Excel's 30 are shown with 30.
      def decimals(count)
        count = count.clamp(0, MOST_DECIMALS)
        @decimals[count] ||= STYLE_FORMATS.size + 1 + @decimals.size
      end

      # Returns [String] the XML of the part: a font, the two fills that Excel requires, a border, the style of a cell
      # without a format, which is first, and the style of each kind of cell, at its index.
      def xml
        formats = FORMATS + @decimals.keys.map { |count| count.zero? ? "0" : "0.#{'0' * count}" }
        styles  = STYLE_FORMATS + @decimals.size.times.map { |index| FIRST_CUSTOM_FORMAT + FORMATS.size + index }
        xml     = +%(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>)
        xml << %(<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">)
        xml << %(<numFmts count="#{formats.size}">)
        formats.each_with_index do |code, index|
          xml << %(<numFmt numFmtId="#{FIRST_CUSTOM_FORMAT + index}" formatCode="#{code}"/>)
        end
        xml << "</numFmts>"
        xml << %(<fonts count="1"><font><sz val="12"/><name val="Calibri"/><family val="2"/></font></fonts>)
        xml << %(<fills count="2"><fill><patternFill patternType="none"/></fill>)
        xml << %(<fill><patternFill patternType="gray125"/></fill></fills>)
        xml << %(<borders count="1"><border/></borders>)
        xml << %(<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>)
        xml << %(<cellXfs count="#{styles.size + 1}"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>)
        styles.each do |format|
          xml << %(<xf numFmtId="#{format}" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>)
        end
        xml << "</cellXfs>"
        xml << %(<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>)
        xml << %(<dxfs count="0"/>)
        xml << %(<tableStyles count="0" defaultTableStyle="TableStyleMedium9" defaultPivotStyle="PivotStyleLight16"/>)
        xml << "</styleSheet>"
      end
    end
  end
end
