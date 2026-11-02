require "csv"

module IOStreams
  module Xlsx
    class Reader < IOStreams::Reader
      def self.option_names
        []
      end

      # Returns [Symbol] the tabular format of the text that a workbook is read as: CSV, one line for each row of its
      # worksheet, see #file.
      def self.text_format
        :csv
      end

      # Convert a xlsx, or xlsm file into CSV format.
      def self.file(file_name, &block)
        # Stream into a temp file as csv
        Utils.private_temp_file("iostreams_csv") do |temp_file_name|
          ::File.open(temp_file_name, "wb") { |io| new(file_name).each { |lines| io << lines.to_csv } }
          ::File.open(temp_file_name, "rb", &block)
        end
      end

      # Returns [Class] the class that reads a workbook for a file read with a schema, see
      # `IOStreams::Builder#stream_class`, whose CSV text holds the text of each number cell as IOStreams 3.0 gives it,
      # see `IOStreams::Xlsx::SchemaReader`, while this class keeps creek's text, as IOStreams 2.1 read it. A subclass,
      # such as one that an application registers for `.xlsx`, reads a file with a schema itself.
      def self.schema_reader
        self == Reader ? SchemaReader : self
      end

      # Returns [Module] the stand-in for the writer of the files that this class reads, which IOStreams 3.0 adds, and
      # IOStreams 2.2 does not have, which answers the options that it takes, see `IOStreams::Xlsx::V3Writer`.
      def self.v3_writer
        V3Writer
      end

      def initialize(file_name)
        begin
          require "creek" unless defined?(Creek::Book)
        rescue LoadError => e
          raise(LoadError, "Please install the 'creek' gem for xlsx streaming support. #{e.message}")
        end

        workbook   = Creek::Book.new(file_name, check_file_extension: false)
        @worksheet = workbook.sheets[0]
      end

      # Returns each [Array] row from the spreadsheet
      def each
        @worksheet.rows.each { |row| yield row.values }
      end

      private

      # Converts each cell of the worksheet with the block, rather than with creek's `Creek::Sheet#convert`, when the
      # block returns a value, which it calls with the text of the cell, its cell type, the index of its style, and
      # `Creek::Sheet#converter_options`, which hold the first day of the workbook, and with creek's conversion when the
      # block returns nil.
      #
      # Raises `IOStreams::Errors::Error` when the version of creek no longer has those methods, rather than let creek
      # convert the cells itself.
      def convert_cells(&block)
        unless @worksheet.respond_to?(:convert, true) && @worksheet.respond_to?(:converter_options, true)
          raise(IOStreams::Errors::Error, "creek #{Creek::VERSION} no longer has Creek::Sheet#convert and " \
                                          "#converter_options, which IOStreams replaces to read the cells of a spreadsheet")
        end

        @worksheet.define_singleton_method(:convert) do |text, type, style_index|
          value = block.call(text, type, style_index.to_i, converter_options)
          value.nil? ? super(text, type, style_index) : value
        end
      end

      # Returns [Array<Symbol|nil>] the class of the number format of each style of the workbook of the worksheet, as
      # IOStreams 3.0 classifies it, see `IOStreams::Xlsx::Cells.number_formats`, rather than as creek does.
      #
      # Raises `IOStreams::Errors::Error` when the version of creek no longer has `Creek::Sheet#book` and
      # `Creek::Styles#styles_xml`, which IOStreams reads the number formats of the workbook from.
      def number_formats
        unless @worksheet.respond_to?(:book) && defined?(Creek::Styles) && Creek::Styles.method_defined?(:styles_xml)
          raise(IOStreams::Errors::Error, "creek #{Creek::VERSION} no longer has Creek::Sheet#book and " \
                                          "Creek::Styles#styles_xml, which IOStreams reads the number formats of a " \
                                          "spreadsheet from")
        end

        Cells.number_formats(Creek::Styles.new(@worksheet.book).styles_xml)
      end
    end
  end
end
