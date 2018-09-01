require 'csv'

module IOStreams
  module Xlsx
    class Reader
      attr_reader :worksheet

      # Read from a xlsx, or xlsm file or stream.
      #
      # Example:
      #   IOStreams::Xlsx::Reader.open('spreadsheet.xlsx') do |spreadsheet_stream|
      #     spreadsheet_stream.each_line do |line|
      #       puts line
      #     end
      #   end
      def self.open(file_name_or_io, buffer_size: 65536, &block)
        begin
          require 'creek' unless defined?(Creek::Book)
        rescue LoadError => e
          raise(LoadError, "Please install the 'creek' gem for xlsx streaming support. #{e.message}")
        end

        if IOStreams.reader_stream?(file_name_or_io)
          temp_file = Tempfile.new('rocket_job_xlsx')
          file_name = temp_file.to_path

          ::File.open(file_name, 'wb') do |file|
            IOStreams.copy(file_name_or_io, file, buffer_size: buffer_size)
          end
        else
          file_name = file_name_or_io
        end

        block.call(self.new(Creek::Book.new(file_name, check_file_extension: false)))
      ensure
        temp_file.delete if temp_file
      end

      def initialize(workbook)
        @worksheet = workbook.sheets[0]
      end

      # Returns each [Array] row from the spreadsheet
      def each(&block)
        worksheet.rows.each { |row| block.call(row.values) }
      end

      alias_method :each_line, :each

    end
  end
end
