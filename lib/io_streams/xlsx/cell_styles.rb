# frozen_string_literal: true

module IOStreams
  module Xlsx
    # The styles of the cells of a workbook that IOStreams writes: the index of the style of each kind of cell that has
    # a number format, which a cell names with its `s` attribute, and the part that holds them, `xl/styles.xml`. A cell
    # holds a date, a date and time, or a time of day as a number, which only its number format says is one, see
    # `IOStreams::Xlsx::Cells`, which reads them back.
    module CellStyles
      # A cell of a date, of the custom format `yyyy-mm-dd`.
      DATE = 1

      # A cell of a date and time, of the custom format `yyyy-mm-dd hh:mm:ss`.
      DATE_TIME = 2

      # A cell of a time of day, of Excel's built-in format 21, `h:mm:ss`.
      TIME_OF_DAY = 3

      # The part, by its name within the workbook.
      PART = "xl/styles.xml"

      # The XML of the part: a font, the two fills that Excel requires, a border, the style of a cell without a format,
      # which is first, and the style of each kind of cell, at its index.
      XML = <<~XML.delete("\n").freeze
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <numFmts count="2">
        <numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd"/>
        <numFmt numFmtId="165" formatCode="yyyy\\-mm\\-dd hh:mm:ss"/>
        </numFmts>
        <fonts count="1"><font><sz val="12"/><name val="Calibri"/><family val="2"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border/></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="4">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        <xf numFmtId="21" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        </cellXfs>
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        <dxfs count="0"/>
        <tableStyles count="0" defaultTableStyle="TableStyleMedium9" defaultPivotStyle="PivotStyleLight16"/>
        </styleSheet>
      XML
    end
  end
end
