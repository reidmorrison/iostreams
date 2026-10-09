require "csv"

module IOStreams
  module Xlsx
    class Writer < IOStreams::Writer
      def self.option_names
        %i[sheet_name auto_format use_shared_strings]
      end

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
      #     Name of the worksheet.
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
      # The stream supplied to the block responds to #write and #<<, and expects CSV text in UTF-8.
      # Each CSV record is parsed into a row, so a quoted value can contain a newline.
      #
      # A workbook is written even when nothing is, with an empty worksheet.
      def self.stream(output_stream, sheet_name: "Sheet1", auto_format: false, use_shared_strings: false)
        Utils.load_soft_dependency("xlsxtream", "Xlsx") unless defined?(Xlsxtream::Workbook)

        workbook = Xlsxtream::Workbook.new(output_stream, auto_format: auto_format, use_shared_strings: use_shared_strings)
        result   = nil
        workbook.write_worksheet(name: sheet_name) do |worksheet|
          writer = new(worksheet)
          result = yield(writer)
          writer.finish
        end
        # Ends the zip file without closing the output stream.
        workbook.close
        result
      end

      # The supplied worksheet receives each row that is written.
      def initialize(worksheet)
        super
        @buffer  = String.new(encoding: Encoding::BINARY)
        @scanned = 0
        @quotes  = 0
      end

      # Write CSV text, which can end part way through a record, since the rest of the record is written next.
      # Returns [Integer] the number of bytes written.
      def write(data)
        data = data.to_s
        @buffer << data.b

        record_start = 0
        while (newline = @buffer.index("\n", @scanned))
          @quotes += @buffer.byteslice(@scanned, newline - @scanned).count('"')
          @scanned = newline + 1
          # A newline within a quoted value, which an odd number of quotes so far leaves open, does not end the record.
          next if @quotes.odd?

          add_row(@buffer.byteslice(record_start, @scanned - record_start))
          record_start = @scanned
          @quotes      = 0
        end
        if record_start.positive?
          @buffer   = @buffer.byteslice(record_start, @buffer.bytesize - record_start)
          @scanned -= record_start
        end
        data.bytesize
      end

      def <<(data)
        write(data)
        self
      end

      # Writes the last record, when it does not end with a newline.
      # Raises [CSV::MalformedCSVError] when it ends within a quoted value.
      def finish
        add_row(@buffer) unless @buffer.empty?
        @buffer = String.new(encoding: Encoding::BINARY)
      end

      private

      def add_row(record)
        output_stream << (CSV.parse_line(record.force_encoding(Encoding::UTF_8)) || [])
      end
    end
  end
end
