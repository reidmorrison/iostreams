# frozen_string_literal: true

module IOStreams
  # Excel workbooks, which are read and written as CSV.
  module Xlsx
    extend StreamFormat

    autoload :Reader, "io_streams/xlsx/reader"
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
  end
end
