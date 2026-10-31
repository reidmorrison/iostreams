# frozen_string_literal: true

require "csv"
require "zlib"

module IOStreams
  module Xlsx
    class Reader < IOStreams::Reader
      def self.option_names
        []
      end

      # Returns [Array<Symbol>] the arguments of the rows that a stream reads, see .file, which are not options.
      def self.argument_names
        %i[rows decimals]
      end

      # Returns [Array<Symbol>] the options of the writer that reading raises for: `sheet_name`, since a caller could
      # expect it to read that worksheet, which it does not, since it reads the first. The other options of the writer
      # are ignored, since the workbook records them.
      def self.unsupported_option_names
        %i[sheet_name]
      end

      # Returns [Module] `IOStreams::Errors::Corrupt` for an exception that creek raises for a file that is not a
      # spreadsheet, see `IOStreams::Reader.failure_kind`: `Zip::Error` from rubyzip, which creek reads the spreadsheet
      # with, for a file that is not a zip file, or `Errno::ENOENT` for a zip file without the parts of a spreadsheet,
      # such as `xl/workbook.xml`.
      def self.failure_kind(exception)
        Errors::Corrupt if (defined?(::Zip::Error) && exception.is_a?(::Zip::Error)) || exception.is_a?(::Errno::ENOENT)
      end

      # Its failures name the spreadsheet that is read, rather than the temp file that a spreadsheet that is not a local
      # file is copied into, see `IOStreams::Reader.takes_display_name?`.
      def self.takes_display_name?
        true
      end

      # Convert a xlsx, or xlsm file into CSV format, or with `rows: true`, see `IOStreams::Xlsx.rows_format`, yield the
      # rows of its first worksheet, each an Array of the value of each of its cells, typed by Excel, see
      # `IOStreams::Xlsx::Cells`.
      #
      # Raises the exception of creek, tagged as `IOStreams::Errors::Corrupt`, for a file that is not a spreadsheet, see
      # .failure_kind, and `IOStreams::Errors::StreamFailure`, tagged the same way, for a part of the spreadsheet that is
      # damaged, see .verify, naming the spreadsheet by its `display_name`, see .takes_display_name?, otherwise by the name
      # of the local file.
      def self.file(file_name, display_name: nil, rows: false, decimals: nil, &block)
        name = display_name || file_name
        verify(file_name, name)
        return yield(Rows.new(file_name, name, decimals: decimals)) if rows

        # Stream into a temp file as csv
        Utils.private_temp_file("iostreams_csv", purpose: "the rows of the spreadsheet as CSV") do |temp_file_name|
          ::File.open(temp_file_name, "wb") do |io|
            tag_failure(name) { new(file_name).each { |lines| io << lines.to_csv } }
          end
          ::File.open(temp_file_name, "rb", &block)
        end
      end

      # Raises unless each part of the spreadsheet has the size and the CRC32 that the spreadsheet records for it, see
      # `IOStreams::Zip::Reader.check_entry`, since rubyzip, which creek reads it with, checks neither, so that a damaged
      # part read wrong values without an error. Reads each part once more, before creek reads it.
      def self.verify(file_name, name)
        Zip::Reader.open_zip(file_name, name).each do |entry|
          next unless entry.file?

          size = 0
          crc  = Zlib.crc32
          tag_failure(name) do
            entry.get_input_stream do |input|
              while (chunk = input.read(65_536))
                size += chunk.bytesize
                crc   = Zlib.crc32(chunk, crc)
              end
            end
          end
          Zip::Reader.check_entry(entry, size, crc, name)
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

      # The rows of the first worksheet of a workbook, each an Array of the value of each of its cells, typed by Excel's own
      # cell type and number format, see `IOStreams::Xlsx::Cells`, rather than by creek, which only reads them.
      class Rows
        include Enumerable

        # The most significant digits that Excel displays of a number, which a number of a column that keeps its digits
        # has, see #initialize.
        DISPLAYED_DIGITS = 15

        # Parameters:
        #   decimals: [#call|nil]
        #     Returns the positions of the values of the rows that keep the digits of their numbers, such as those of a
        #     `number` field, rather than the Float that Excel holds, so that each number of the column is the BigDecimal
        #     of the digits that Excel displays, such as `0.3` for the Float `0.30000000000000004`, or nil until they are
        #     known, once the header row is read, so it is called before each row until it returns them. The stream
        #     supplies it for its schema or contract, which the reader never sees, as JSON keeps the digits of its numbers.
        #     Default: nil, every number is a Float.
        def initialize(file_name, display_name, decimals: nil)
          @file_name    = file_name
          @display_name = display_name
          @decimals     = decimals
        end

        # Yields [Array] each row, as an Array of the values of its cells, from the first, the header row of a worksheet
        # with one, see `IOStreams::Tabular`, and the empty cells before a cell that holds a value as nil.
        #
        # Raises the exception of creek, tagged as `IOStreams::Errors::Corrupt`, for a worksheet that it cannot read, see
        # `IOStreams::Xlsx::Reader.failure_kind`.
        def each
          return enum_for(:each) unless block_given?

          sheet   = Reader.tag_failure(@display_name) { Reader.new(@file_name).worksheet }
          formats = Reader.tag_failure(@display_name) { Cells.number_formats(Creek::Styles.new(sheet.book).styles_xml) }
          type_cells(sheet, formats)
          positions = nil
          each_row(sheet) do |row|
            positions ||= @decimals&.call
            positions&.each { |index| row[index] = displayed(row[index]) }
            yield(row)
          end
        end

        private

        # Types each cell of the worksheet by Excel's own cell type and number format, see `IOStreams::Xlsx::Cells.value`,
        # in place of creek's `Creek::Sheet#convert`, which it calls with `#converter_options` for each cell.
        #
        # Raises `IOStreams::Errors::Error` when the version of creek no longer has those methods, rather than let creek
        # type the cells itself.
        def type_cells(sheet, formats)
          unless sheet.respond_to?(:convert, true) && sheet.respond_to?(:converter_options, true)
            raise(IOStreams::Errors::Error, "creek #{Creek::VERSION} no longer has Creek::Sheet#convert and " \
                                            "#converter_options, which IOStreams replaces to type the cells of a spreadsheet")
          end

          sheet.define_singleton_method(:convert) do |text, type, style_index|
            Cells.value(text, type, formats[style_index.to_i], converter_options)
          end
        end

        # Returns [BigDecimal|Object] the digits of a Float that Excel displays, its most significant 15, or any other
        # value as it is.
        def displayed(value)
          return value unless value.is_a?(Float) && value.finite?

          number = BigDecimal(value.to_s)
          number.zero? ? number : number.round(DISPLAYED_DIGITS - number.exponent)
        end

        # Yields the values of each row of the worksheet, tagging a failure of creek as `.failure_kind` says, but not one
        # that the block raises, which creek raises as it is, as it calls the block while it reads the worksheet.
        def each_row(sheet)
          in_block = false
          sheet.rows.each do |row|
            in_block = true
            yield(row.values)
            # Not reset in an ensure, which would clear it before the exception that the block raised reaches the rescue.
            in_block = false
          end
          nil
        rescue StandardError => e
          raise if in_block

          kind = Reader.failure_kind(e)
          raise(kind ? kind.tag(e, @display_name) : e)
        end
      end

      # Returns [Creek::Sheet] the first worksheet of the workbook, which #each reads.
      attr_reader :worksheet

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
