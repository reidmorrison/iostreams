require 'csv'

module IOStreams
  module Xlsx
    class Reader
      # Convert a xlsx, or xlsm file or stream into CSV format.
      def self.open(file_name_or_io, _ = nil, &block)
        return extract_csv(file_name_or_io, &block) if file_name_or_io.is_a?(String)

        # Creek gem can only work against a file, not a stream, so create temp file.
        IOStreams::File::Path.temp_file_name('iostreams_xlsx') do |temp_file_name|
          IOStreams.copy(file_name_or_io, temp_file_name, target_options: {streams: []})
          extract_csv(temp_file_name, &block)
        end
      end

      # Convert the spreadsheet to csv in a tempfile
      def self.extract_csv(file_name, &block)
        IOStreams::File::Path.temp_file_name('iostreams_csv') do |temp_file_name|
          IOStreams::File::Writer.open(temp_file_name) do |io|
            new(file_name).each { |lines| io << lines.to_csv }
          end
          IOStreams::File::Reader.open(temp_file_name, &block)
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
