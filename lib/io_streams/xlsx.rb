module IOStreams
  # Excel workbooks, which are read as CSV. They cannot be written.
  module Xlsx
    autoload :Reader, "io_streams/xlsx/reader"

    # Returns [Class] the class that reads a workbook.
    def self.reader_class
      Reader
    end

    # Returns [nil] since workbooks cannot be written.
    def self.writer_class
      nil
    end

    # Returns [true|false] whether data in this format is compressed: true, since a workbook is a zip file.
    def self.compressed?
      true
    end

    # Returns [true|false] whether data in this format is encrypted.
    def self.encrypted?
      false
    end
  end
end
