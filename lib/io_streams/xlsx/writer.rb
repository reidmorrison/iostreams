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

      # Raises ArgumentError for a `sheet_name` that Excel rejects, which would make it report the workbook as corrupt,
      # and LoadError when the `xlsxtream` gem is not installed, so that they raise before a path opens its output, which
      # would replace an existing file, see `IOStreams::StreamFormat#check_stream`.
      #
      # Excel rejects a name that is empty, longer than 31 characters, contains any of `[ ] : * ? / \`, or starts or
      # ends with an apostrophe.
      def self.check(sheet_name: "Sheet1", auto_format: false, use_shared_strings: false) # rubocop:disable Lint/UnusedMethodArgument
        Utils.load_soft_dependency("xlsxtream", "Xlsx") unless defined?(Xlsxtream::Workbook)

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
      # The stream supplied to the block responds to the methods of an IO that write, see `IOStreams::Writable`, and
      # expects CSV text in UTF-8. Each CSV record is parsed into a row, so a quoted value can contain a newline.
      #
      # A workbook is written even when nothing is, with an empty worksheet.
      #
      # The workbook is ended when the block returns, including when it leaves early, such as with `break`, so that
      # what was written is a complete workbook. It is not ended when the block raises, or its thread is killed, so
      # that the output is not a workbook that can be read.
      def self.stream(output_stream, sheet_name: "Sheet1", auto_format: false, use_shared_strings: false)
        check(sheet_name: sheet_name, auto_format: auto_format, use_shared_strings: use_shared_strings)

        workbook  = Xlsxtream::Workbook.new(output_stream, auto_format: auto_format, use_shared_strings: use_shared_strings)
        # Rather than the block form, which ends the worksheet after its block without an `ensure`.
        worksheet = workbook.add_worksheet(name: sheet_name)
        writer    = new(worksheet)
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
      end

      # Writes the last record, when it does not end with a line break.
      # Raises [CSV::MalformedCSVError] when it ends within a quoted value.
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
      def write_data(data)
        @buffer << data.b

        record_start = 0
        while (line_break = @buffer.index(LINE_BREAK, @scanned))
          @quotes += @buffer.byteslice(@scanned, line_break - @scanned).count('"')
          @scanned = line_break
          # A line break within a quoted value, which an odd number of quotes so far leaves open, does not end the record.
          if @quotes.odd?
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
      def add_row(record)
        output_stream << (CSV.parse_line(record.force_encoding(Encoding::UTF_8)) || [])
      end
    end
  end
end
