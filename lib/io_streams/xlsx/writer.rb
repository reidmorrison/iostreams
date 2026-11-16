# frozen_string_literal: true

require "csv"

module IOStreams
  module Xlsx
    class Writer < IOStreams::Writer
      include Writable

      # The characters that Excel does not allow in the name of a worksheet.
      INVALID_SHEET_NAME_CHARACTERS = %r{[\[\]:*?/\\]}

      # The bytes that can end a CSV record.
      LINE_BREAK      = /[\r\n]/n
      CARRIAGE_RETURN = "\r".ord
      NEWLINE         = "\n".ord

      def self.option_names
        %i[sheet_name auto_format use_shared_strings]
      end

      # Returns [Array<Symbol>] the arguments of the rows that a stream writes, see .stream, which are not options.
      def self.argument_names
        %i[rows text_columns time_columns]
      end

      # Raises ArgumentError for a `sheet_name` that Excel rejects, which would make it report the workbook as corrupt,
      # LoadError when the `xlsxtream` gem is not installed, and `IOStreams::Errors::Error` for columns of times of day,
      # `time_columns`, when the version of `xlsxtream` does not write the styles that `IOStreams::Xlsx::Workbook` adds
      # the style of a time of day to, see `IOStreams::Xlsx::Workbook.check`, so that they raise before a path opens its
      # output, which would replace an existing file, see `IOStreams::StreamFormat#check_stream`.
      #
      # Excel rejects a name that is empty, longer than 31 characters, contains any of `[ ] : * ? / \`, or starts or
      # ends with an apostrophe.
      # rubocop:disable-next Lint/UnusedMethodArgument -- takes the arguments of .stream, which only it uses
      def self.check(sheet_name: "Sheet1", auto_format: false, use_shared_strings: false, rows: false, text_columns: nil,
                     time_columns: nil)
        Utils.load_soft_dependency("xlsxtream", "Xlsx") unless defined?(Xlsxtream::Workbook)
        Workbook.check if time_columns&.any?

        problem = sheet_name_problem(sheet_name)
        raise(ArgumentError, "Invalid sheet_name #{sheet_name.inspect}: #{problem}") if problem
      end

      # Returns [String|nil] why the name of the worksheet cannot be written, or nil when it can, including nil, for
      # which the worksheet is named "Sheet1".
      def self.sheet_name_problem(sheet_name)
        if sheet_name.nil? then nil
        elsif !sheet_name.is_a?(String) then "supply the name of the worksheet as a String"
        elsif sheet_name.empty? then "Excel rejects an empty name for a worksheet"
        elsif sheet_name.length > 31 then "Excel rejects the name of a worksheet that is longer than 31 characters"
        elsif sheet_name.match?(INVALID_SHEET_NAME_CHARACTERS)
          "Excel rejects the name of a worksheet that contains any of [ ] : * ? / \\"
        elsif sheet_name.start_with?("'") || sheet_name.end_with?("'")
          "Excel rejects the name of a worksheet that starts or ends with an apostrophe"
        end
      end
      private_class_method :sheet_name_problem

      # Write CSV text as the rows of a workbook with one worksheet, to the supplied output stream.
      #
      # The workbook is streamed with `xlsxtream`, which is built on `zip_kit`, so it is written straight to
      # the output stream without a temp file, even when the output cannot seek, such as a pipe to `gpg`.
      #
      # Parameters
      #   output_stream [IO]
      #     Output stream to write to
      #
      #   sheet_name: [String]
      #     Name of the worksheet, which Excel limits, see .check.
      #     Default: "Sheet1"
      #
      #   auto_format: [true|false]
      #     Whether to write values that look like numbers, dates, times or booleans, such as "1.5" or
      #     "2026-10-09", as Excel numbers, dates and booleans. Values such as "01234" may then not read back
      #     exactly as they were written.
      #     Default: false, every cell is written as text, so reading the workbook returns the same CSV.
      #
      #   use_shared_strings: [true|false]
      #     Whether to store each distinct value once in a shared string table, which makes the workbook
      #     smaller when values repeat, but holds every distinct value in memory until the workbook is complete.
      #     Default: false
      #
      #   rows: [true|false]
      #     Whether the block writes rows rather than CSV text, see `IOStreams::Xlsx.rows_format`: each an Array of the
      #     values of its cells, which keep their types, or nil for a blank row, written as a row without cells, see
      #     `IOStreams::Xlsx::RowsWriter`.
      #     Default: false
      #
      #   text_columns: [Array<Integer>]
      #     With `rows: true`, the positions of the columns whose values are text by their field of a schema or contract,
      #     whose text `auto_format` leaves as it is, such as `01234`, since it only converts the values of columns
      #     whose type is not known.
      #     Default: none
      #
      #   time_columns: [Array<Integer>]
      #     With `rows: true`, the positions of the columns whose values are times of day by their field of a schema or
      #     contract, a `time`, whose cells are written as times of day, of Excel's time format `h:mm:ss`, rather than as
      #     dates and times, see `IOStreams::Xlsx::Workbook`, which needs `xlsxtream` 3.0 or later, see .check.
      #     Default: none
      #
      # The stream supplied to the block responds to the methods of an IO that write, see `IOStreams::Writable`, and
      # expects CSV text in UTF-8. Each CSV record is parsed into a row, so a quoted value can contain a newline. A record
      # whose quoting is not valid raises the csv gem's `CSV::MalformedCSVError`, tagged as an
      # `IOStreams::Errors::RowError` that names the line of the CSV text that the record starts on, see #add_row.
      #
      # A workbook is written even when nothing is, with an empty worksheet.
      #
      # The workbook is ended when the block returns, including when it leaves early, such as with `break`, so that
      # what was written is a complete workbook. It is not ended when the block raises, or its thread is killed, so
      # that the output is not a workbook that can be read.
      def self.stream(output_stream, sheet_name: "Sheet1", auto_format: false, use_shared_strings: false, rows: false,
                      text_columns: nil, time_columns: nil)
        check(sheet_name: sheet_name, auto_format: auto_format, use_shared_strings: use_shared_strings,
              time_columns: time_columns)

        # Rows hold their types, so only the values of the columns whose type is not known are formatted, see RowsWriter.
        # Only a workbook with a column of times of day adds their style to those of `xlsxtream`, see Workbook.
        workbook  = (time_columns&.any? ? Workbook : Xlsxtream::Workbook).
                    new(output_stream, auto_format: auto_format && !rows, use_shared_strings: use_shared_strings)
        # Rather than the block form, which ends the worksheet after its block without an `ensure`.
        worksheet = workbook.add_worksheet(name: sheet_name)
        writer    =
          if rows
            RowsWriter.new(worksheet, auto_format: auto_format, text_columns: text_columns, time_columns: time_columns)
          else
            new(worksheet)
          end
        finish    = lambda do
          writer.finish
          worksheet.close
          # Ends the zip file without closing the output stream.
          workbook.close
        end
        Utils.finish_or_abort(finish: finish) { yield(writer) }
      end

      # The supplied worksheet receives each row that is written.
      def initialize(worksheet)
        super
        @buffer  = String.new(encoding: Encoding::BINARY)
        @scanned = 0
        @quotes  = 0
        # The line of the CSV text that the next record starts on, and the line breaks within the quoted values of the
        # record being read, so that a record that cannot be parsed names its line, see #add_row.
        @line_number = 1
        @breaks      = 0
      end

      # Writes the last record, when it does not end with a line break.
      # Raises [CSV::MalformedCSVError] tagged as an `IOStreams::Errors::RowError` when it ends within a quoted value,
      # see #add_row.
      def finish
        unless @buffer.empty?
          # A carriage return that ends the data, outside a quoted value, which an even number of quotes leaves closed,
          # ends the last record, see #write_data.
          ends = @buffer.end_with?("\r") && @buffer.count('"').even?
          add_row(ends ? @buffer.byteslice(0, @buffer.bytesize - 1) : @buffer)
        end
        @buffer = String.new(encoding: Encoding::BINARY)
      end

      private

      # Write CSV text, which can end part way through a record, since the rest of the record is written next.
      # Returns [Integer] the number of bytes written.
      #
      # A record ends with a line break, "\r\n", "\n" or "\r", outside a quoted value, whichever line ending the CSV
      # was written with, such as with `writer(:line, delimiter: "\r")`.
      #
      # The text of a spreadsheet is UTF-8, so text in another encoding is converted to UTF-8, such as a Windows-1252
      # String written with `#puts`, which writes each object in its own encoding, while binary data, such as the
      # bytes of a file being copied, is UTF-8 already.
      def write_data(data)
        data = data.encode(Encoding::UTF_8) unless [Encoding::BINARY, Encoding::UTF_8].include?(data.encoding)
        @buffer << data.b

        record_start = 0
        while (line_break = @buffer.index(LINE_BREAK, @scanned))
          @quotes += @buffer.byteslice(@scanned, line_break - @scanned).count('"')
          @scanned = line_break
          # A line break within a quoted value, which an odd number of quotes so far leaves open, does not end the record.
          if @quotes.odd?
            @breaks  += 1 unless crlf_end?(line_break)
            @scanned += 1
            next
          end

          record_end = line_break + 1
          if @buffer.getbyte(line_break) == CARRIAGE_RETURN
            # Until the next byte is written, a carriage return could be the start of "\r\n".
            break if record_end == @buffer.bytesize

            record_end += 1 if @buffer.getbyte(record_end) == NEWLINE
          end
          add_row(@buffer.byteslice(record_start, line_break - record_start))
          record_start = @scanned = record_end
          @quotes      = 0
        end
        if record_start.positive?
          @buffer   = @buffer.byteslice(record_start, @buffer.bytesize - record_start)
          @scanned -= record_start
        end
        data.bytesize
      end

      # Writes the row of the CSV record, without its line break, so that a line break within a quoted value is read
      # as part of the value, whichever line ending the record has.
      #
      # Raises [CSV::MalformedCSVError] for a record whose quoting is not valid, tagged as an
      # `IOStreams::Errors::RowError` as the CSV parser tags it, see `IOStreams::Tabular::Parser::Csv.row_error`, at the
      # line of the CSV text that the record starts on, such as "Illegal quoting, on line 2", so that a caller rescues
      # the error of IOStreams rather than that of the gem. The CSV text has no record numbers, since only the writer of
      # the text knows whether it starts with a header row.
      def add_row(record)
        begin
          row = CSV.parse_line(record.force_encoding(Encoding::UTF_8))
        rescue CSV::MalformedCSVError => e
          raise IOStreams::Tabular::Parser::Csv.row_error(e).at(line_number: @line_number)
        end
        output_stream << (row || [])
        @line_number += 1 + @breaks
        @breaks       = 0
      end

      # Returns [true|false] whether the line break at the supplied index of the buffer is the newline of a "\r\n",
      # whose carriage return was counted as the line break, see #write_data.
      def crlf_end?(index)
        index.positive? && @buffer.getbyte(index) == NEWLINE && @buffer.getbyte(index - 1) == CARRIAGE_RETURN
      end
    end
  end
end
