# frozen_string_literal: true

module IOStreams
  # Excel workbooks, whose bytes and lines are read and written as CSV, and whose rows and records are the values of
  # their cells, typed by Excel, see `IOStreams::Xlsx::Cells`.
  module Xlsx
    extend StreamFormat

    autoload :Cells,  "io_streams/xlsx/cells"
    autoload :Reader, "io_streams/xlsx/reader"
    autoload :RowsWriter, "io_streams/xlsx/rows_writer"
    autoload :Writer, "io_streams/xlsx/writer"

    # Returns [Class] the class that reads a workbook.
    def self.reader_class
      Reader
    end

    # Returns [Class] the class that writes a workbook.
    def self.writer_class
      Writer
    end

    # Returns [true|false] whether data in this format is compressed: true, since a workbook is a zip file.
    def self.compressed?
      true
    end

    # Returns [true|false] whether data in this format is encrypted.
    def self.encrypted?
      false
    end

    # Returns [Symbol] the tabular format of the text that a workbook is read as, and written from: CSV, one line
    # for each row of its worksheet, see `IOStreams::StreamFormat#text_format`.
    def self.text_format
      :csv
    end

    # Returns [Symbol] the tabular format of the rows that a workbook is read and written as, when the rows and records
    # of a stream are read or written, rather than its lines: `:array`, an Array of the value of each cell of a row,
    # typed by Excel, see `IOStreams::Xlsx::Cells`, rather than as text, see `IOStreams::StreamFormat#rows_format`.
    def self.rows_format
      :array
    end
  end
end
