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
        %i[rows decimals strings missing]
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
      def self.file(file_name, display_name: nil, rows: false, decimals: nil, strings: nil, missing: nil, &block)
        name = display_name || file_name
        verify(file_name, name)
        return yield(Rows.new(file_name, name, decimals: decimals, strings: strings, missing: missing)) if rows

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

      # Returns each [Array] row from the spreadsheet, with the text of each cell, as `IOStreams::Xlsx::Cells.text` gives
      # it, the same in every process, so that the lines and the rows of the workbook agree on which cells hold a date or
      # a time, or nil for an empty cell.
      def each
        formats = self.class.number_formats(@worksheet)
        self.class.convert_cells(@worksheet) { |text, type, style, options| Cells.text(text, type, formats[style], options) }
        @worksheet.rows.each { |row| yield(row.values) }
      end

      # Replaces creek's conversion of each cell of a worksheet, `Creek::Sheet#convert`, with the block, which it calls
      # with the text of the cell, its cell type, the index of its style, and `Creek::Sheet#converter_options`, the
      # shared strings and the first day of the workbook, so that IOStreams types its cells, see
      # `IOStreams::Xlsx::Cells`, rather than creek, which only reads them.
      #
      # Raises `IOStreams::Errors::Error` when the version of creek no longer has those methods, rather than let creek
      # type the cells itself.
      def self.convert_cells(sheet, &block)
        unless sheet.respond_to?(:convert, true) && sheet.respond_to?(:converter_options, true)
          raise(IOStreams::Errors::Error, "creek #{Creek::VERSION} no longer has Creek::Sheet#convert and " \
                                          "#converter_options, which IOStreams replaces to type the cells of a spreadsheet")
        end

        sheet.define_singleton_method(:convert) do |text, type, style_index|
          block.call(text, type, style_index.to_i, converter_options)
        end
      end

      # Returns [Array<Symbol|nil>] the class of the number format of each style of the workbook of a worksheet, see
      # `IOStreams::Xlsx::Cells.number_formats`.
      def self.number_formats(sheet)
        Cells.number_formats(Creek::Styles.new(sheet.book).styles_xml)
      end

      # The rows of the first worksheet of a workbook, each an Array of the value of each of its cells, typed by Excel's own
      # cell type and number format, see `IOStreams::Xlsx::Cells`, rather than by creek, which only reads them.
      class Rows
        include Enumerable

        # The most significant digits that Excel displays of a number, which a number of a column that keeps its digits
        # has, see #initialize.
        DISPLAYED_DIGITS = 15

        # The whole numbers that a Float holds exactly, below 2**53, which keep every digit, see #displayed.
        EXACT_WHOLE = 2**53

        # Parameters:
        #   decimals: [#call|nil]
        #     Returns the positions of the values of the rows that keep the digits of their numbers, such as those of a
        #     `number` field, rather than the Float that Excel holds, so that each number of the column is the BigDecimal
        #     of the digits that Excel displays, such as `0.3` for the Float `0.30000000000000004`, or nil until they are
        #     known, once the header row is read, so it is called before each row until it returns them. The stream
        #     supplies it for its schema or contract, which the reader never sees, as JSON keeps the digits of its numbers.
        #     Default: nil, every number is a Float.
        #
        #   strings: [#call|nil]
        #     Returns the positions of the values of the rows that are text, such as those of a `string` field, so that
        #     each number of the column is the text of the number that the cell holds, to the digits that Excel displays,
        #     see `decimals`, such as `2134` for the zip code that Excel holds as the Float `2134.0`, and each cell of a
        #     time of day the time of its clock, such as `09:30:00`, see `IOStreams::Xlsx::Cells.clock`, or nil until
        #     they are known, as for `decimals`.
        #     Default: nil, every number is a Float, and every time of day a Time.
        #
        #   missing: [#call|nil]
        #     Returns the positions of the values of the rows whose text can be a missing value other than empty text,
        #     such as "-99", with what answers whether the text of a cell is one of them, `#call(text)`, so that such a
        #     cell is that text, whatever Excel holds, such as the number -99, which its field reads as a missing value,
        #     as Frictionless compares the text of a value with its missing values before it reads its type, or nil until
        #     they are known, as for `decimals`. The text of a cell is the text that the CSV text of the worksheet holds,
        #     see `IOStreams::Xlsx::Cells.text`. So a row whose every cell is a missing value is not blank, and is read as
        #     a record whose every value is missing, as its CSV text is.
        #     Default: nil, no cell is compared.
        def initialize(file_name, display_name, decimals: nil, strings: nil, missing: nil)
          @file_name    = file_name
          @display_name = display_name
          @decimals     = decimals
          @strings      = strings
          @missing      = missing
        end

        # Yields [Array] each row, as an Array of the values of its cells, from the first, the header row of a worksheet
        # with one, see `IOStreams::Tabular`, and the empty cells before a cell that holds a value as nil.
        #
        # Raises the exception of creek, tagged as `IOStreams::Errors::Corrupt`, for a worksheet that it cannot read, see
        # `IOStreams::Xlsx::Reader.failure_kind`.
        def each
          return enum_for(:each) unless block_given?

          sheet     = Reader.tag_failure(@display_name) { Reader.new(@file_name).worksheet }
          clocks    = type_cells(sheet)
          positions = nil
          texts     = nil
          missing   = nil
          each_row(sheet) do |row|
            if @missing
              missing ||= @missing.call
              read_cells(row, missing, clocks)
            end
            positions ||= @decimals&.call
            texts     ||= @strings&.call
            positions&.each { |index| row[index] = displayed(row[index]) }
            texts&.each { |index| row[index] = clocks[row[index]] || displayed_text(row[index]) }
            row.each { |value| clocks.delete(value) } unless clocks.empty?
            yield(row)
          end
        end

        private

        # Types the cells of the worksheet by Excel's own cell type and number format, see `IOStreams::Xlsx::Cells.value`.
        #
        # Returns [Hash] the time of the clock of each cell of a time of day, by the Time that the cell holds, itself,
        # rather than its value, since a cell of a date and time can hold the same time, see
        # `IOStreams::Xlsx::Cells.clock`, which a `string` field reads, see #initialize, filled as the worksheet is read,
        # and only when a field is a `string`.
        #
        # When the text of a cell can be a missing value, see `missing` in #initialize, each cell is its value with its
        # text, a Cell, until #read_cells reads the row.
        def type_cells(sheet)
          formats = Reader.tag_failure(@display_name) { Reader.number_formats(sheet) }
          clocks  = {}.compare_by_identity
          Reader.convert_cells(sheet) do |text, type, style, options|
            value = Cells.value(text, type, formats[style], options)
            clock = @strings && Cells.clock(text, type, formats[style])
            clocks[value] = clock if clock
            @missing ? Cell.new(value, Cells.text(text, type, formats[style], options)) : value
          end
          clocks
        end

        # The value of a cell with its text, see `IOStreams::Xlsx::Cells.text`, which a missing value is compared with,
        # see `missing` in #initialize, until #read_cells reads the row.
        Cell = Struct.new(:value, :text)

        # Replaces each cell of the row with its value, or its text when that is a missing value of the field of its
        # position, see `missing` in #initialize, which the field reads as missing, forgetting the clock of a time that is
        # missing, see #type_cells.
        def read_cells(row, missing, clocks)
          row.each_with_index do |cell, index|
            next unless cell.is_a?(Cell)

            missing_value = missing&.[](index)
            if missing_value&.call(cell.text)
              clocks.delete(cell.value)
              row[index] = cell.text
            else
              row[index] = cell.value
            end
          end
        end

        # Returns [BigDecimal|Object] the number of a Float that the cell holds, to the digits that Excel displays, its
        # most significant 15, such as `0.3` for `0.30000000000000004`, apart from a whole number below 2**53, which a
        # Float holds exactly, which keeps every digit, such as the card number `4111111111111111`, or any other value
        # as it is.
        #
        # The exact value of the Float is rounded half up, to the digits counted from the first significant digit of its
        # shortest text, rather than that text, so that the digits are the same on every Ruby, since JRuby writes the
        # text of some Floats with other digits than MRI does. Rounded so, the number has at most one more digit than
        # Excel displays, which the BigDecimal holds exactly.
        def displayed(value)
          return value unless value.is_a?(Float) && value.finite?
          return BigDecimal(value.to_i) if value == value.truncate && value.abs < EXACT_WHOLE

          digits = DISPLAYED_DIGITS - BigDecimal(value.to_s).exponent
          BigDecimal(value.to_r.round(digits, half: :up), DISPLAYED_DIGITS + 1)
        end

        # Returns [String|Object] the text of the number of a Float that the cell holds, see #displayed, in plain digits,
        # without a decimal point for a whole number, such as "2134" for `2134.0`, "0.3" for `0.30000000000000004`, or
        # "0.0000001" for `1e-7`, or any other value as it is.
        def displayed_text(value)
          return value unless value.is_a?(Float) && value.finite?
          return value.to_i.to_s if value.abs < EXACT_WHOLE && value == value.truncate

          number = displayed(value)
          number.frac.zero? ? number.to_i.to_s : number.to_s("F")
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
    end
  end
end
