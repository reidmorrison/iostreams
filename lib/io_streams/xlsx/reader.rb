require "csv"

module IOStreams
  module Xlsx
    class Reader < IOStreams::Reader
      def self.option_names
        []
      end

      # Returns [Array<Symbol>] the options of the writer that are ignored when reading, since the workbook
      # records them. Not `sheet_name`, since a caller could expect it to read that worksheet, which it does not.
      def self.valid_option_names
        %i[auto_format use_shared_strings]
      end

      # Convert a xlsx, or xlsm file into CSV format.
      def self.file(file_name, &block)
        # Stream into a temp file as csv
        Utils.private_temp_file("iostreams_csv", purpose: "the rows of the spreadsheet as CSV") do |temp_file_name|
          ::File.open(temp_file_name, "wb") { |io| new(file_name).each { |lines| io << lines.to_csv } }
          ::File.open(temp_file_name, "rb", &block)
        end
      end

      # Reads with creek rather than xsv, for now. xsv (checked at 1.4.1) loses data when converting cells: it rounds
      # datetimes to the minute, returns a time of day as "HH:MM", misreads a lowercase exponent (1e+20 as 1), leaves
      # _xHHHH_ escapes such as _x000D_ undecoded, ignores date1904, turns errors such as #N/A into nil, strips
      # formula results, returns gap rows as rows of nil, and pads every row to the sheet's width. It has no option to
      # return raw values. Revisit once xsv resolves these type conversion issues.
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
