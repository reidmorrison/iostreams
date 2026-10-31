require "csv"

module IOStreams
  module Xlsx
    class Reader < IOStreams::Reader
      def self.option_names
        []
      end

      # Convert a xlsx, or xlsm file into CSV format.
      def self.file(file_name, &block)
        # Stream into a temp file as csv
        Utils.private_temp_file("iostreams_csv") do |temp_file_name|
          ::File.open(temp_file_name, "wb") { |io| new(file_name).each { |lines| io << lines.to_csv } }
          ::File.open(temp_file_name, "rb", &block)
        end
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
    end
  end
end
