# frozen_string_literal: true

require "csv"

module IOStreams
  module Xlsx
    class Reader < IOStreams::Reader
      def self.option_names
        []
      end

      # Returns [Array<Symbol>] the options of the writer that reading raises for: `sheet_name`, since a caller could
      # expect it to read that worksheet, which it does not, since it reads the first. The other options of the writer
      # are ignored, since the workbook records them.
      def self.unsupported_option_names
        %i[sheet_name]
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
        Utils.load_soft_dependency("creek", "Xlsx") unless defined?(Creek::Book)

        workbook   = Creek::Book.new(file_name, check_file_extension: false)
        @worksheet = workbook.sheets[0]
      end

      # Returns each [Array] row from the spreadsheet, with the text of each value, see .cell_text.
      def each
        @worksheet.rows.each { |row| yield(row.values.map { |value| self.class.cell_text(value) }) }
      end

      # Returns [String|nil] the text of the value of a cell, as a field of type "any" writes it, see
      # `IOStreams::Schema::Field.any_text`, so that a field of type date or datetime can read it: a Date in ISO 8601,
      # such as "2026-01-02", and a BigDecimal as a plain decimal, such as "12.5", where `Array#to_csv` wrote "0.125e2".
      #
      # A time is written as its time of day in UTC, such as "2026-01-02T09:30:00Z", since Excel holds it without a
      # time zone, so that the text is the same in every process, while creek returns it in the local time zone of the
      # process that reads it, such as "2026-01-02 09:30:00 -0500".
      #
      # An empty cell is nil, and any other value, such as a String, an Integer or a Float, has the text that
      # `Array#to_csv` gives it.
      def self.cell_text(value)
        return if value.nil?
        return Schema::Field.any_text(value) unless value.is_a?(Time)

        Schema::Field.any_text(Time.utc(value.year, value.month, value.day, value.hour, value.min, value.sec + value.subsec))
      end
    end
  end
end
