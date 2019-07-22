require 'csv'

module IOStreams
  module Xlsx
    class Reader
      # Convert a xlsx, or xlsm file or stream into CSV format.
      def self.open(file_name_or_io, _ = nil)
        if file_name_or_io.is_a?(String)
          file_name = file_name_or_io
        else
          temp_file = Tempfile.new('iostreams_xlsx')
          temp_file.binmode
          IOStreams.copy(file_name_or_io, temp_file)
          file_name = temp_file.to_path
        end

        csv_temp_file = Tempfile.new('iostreams_csv')
        csv_temp_file.binmode
        new(file_name).each { |lines| csv_temp_file << lines.to_csv }
        csv_temp_file.rewind
        yield csv_temp_file
      ensure
        temp_file.delete if temp_file
        csv_temp_file.delete if csv_temp_file
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
