require 'csv'

module IOStreams
  module Xlsx
    class Reader < IOStreams::Reader
      # Convert a xlsx, or xlsm file into CSV format.
      def self.file(file_name, original_file_name: file_name, &block)
        # Stream into a temp file as csv
        # IOStreams::Paths::File.temp_file('iostreams_csv') do |temp_file|
        #   temp_file.writer { |io| new(file_name).each { |lines| io << lines.to_csv } }
        #   temp_file.reader(&block)
        # end
        IOStreams::Paths::File.temp_file_name('iostreams_csv') do |temp_file_name|
          ::File.open(temp_file_name, 'wb') { |io| new(file_name).each { |lines| io << lines.to_csv } }
          ::File.open(temp_file_name, 'rb', &block)
        end
      end

      def initialize(file_name)
        begin
          require 'creek' unless defined?(Creek::Book)
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
