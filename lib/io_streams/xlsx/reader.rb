begin
  require 'creek'
rescue LoadError => e
  puts "Install the 'creek' gem for xlsx streaming support"
  raise(e)
end
require 'csv'

module IOStreams
  module Xlsx
    class Reader
      attr_reader :worksheet

      def initialize(workbook)
        @worksheet = workbook.sheets[0]
      end

      def each_line(&block)
        worksheet.rows.each do |row|
          block.call(row.values.to_csv(row_sep: nil))
        end
      end

      # Read from a xlsx, or xlsm file or stream.
      #
      # Example:
      #   IOStreams::Xlsx::Reader.open('spreadsheet.xlsx') do |spreadsheet_stream|
      #     spreadsheet_stream.each_line do |line|
      #       puts line
      #     end
      #   end
      def self.open(file_name_or_io, options={}, &block)
        options     = options.dup
        buffer_size = options.delete(:buffer_size) || 65536
        raise(ArgumentError, "Unknown IOStreams::Xlsx::Reader option: #{options.inspect}") if options.size > 0

        if IOStreams.reader_stream?(file_name_or_io)
          temp_file = Tempfile.new('rocket_job_xlsx')
          file_name = temp_file.to_path

          ::File.open(file_name, 'wb') do |file|
            IOStreams.copy(file_name_or_io, file, buffer_size)
          end
        else
          file_name = file_name_or_io
        end

        block.call(self.new(Creek::Book.new(file_name, check_file_extension: false)))
      ensure
        temp_file.delete if temp_file
      end

    end
  end
end
