# frozen_string_literal: true

module IOStreams
  class Slice
    # Writes slices, see `IOStreams::Slice`, to a file, for `IOStreams::Stream#writer(:slice)`, which creates it with the
    # writer of the lines of the file and the tabular of the stream, so that the slices that `#each(:slice)` read from
    # one file, or that a store of slices holds, see `IOStreams::Slice::Target`, are written to another:
    #
    #   IOStreams.path("people.csv.gz").schema(schema).writer(:slice) do |io|
    #     slices.each { |slice| io << slice }
    #   end
    #
    # Every slice is of the same file as the first one written, see `IOStreams::Slice#same_file?`: the same header row and
    # format, and alike in whether its blank rows are records, the text of its values the default text of IOStreams,
    # and its values typed. The rows of every slice
    # are read by one reader, see `IOStreams::Tabular#for_format`, as the rows of one file, whether they start with a
    # header row being as the slice says, see `IOStreams::Slice#header?`, whatever the schema says of the file written.
    # The header row of the file is written once, before the rows of the first slice, and each row after it, in the
    # order written:
    # - A slice whose rows are lines of the format of the file, and that has a header row when the file has one, is
    #   written as it is, line for line, without parsing its rows, as `#each(:slice)` reads them, after its header row
    #   is matched to the fields of the schema, which raises `IOStreams::Errors::InvalidHeader` when they do not match,
    #   unless its values are the cells of a source of typed values, such as the CSV text of a spreadsheet, see
    #   `IOStreams::Slice#cell_text?`, whose text the schema of the file may describe otherwise. A row of it that is
    #   already parsed, an Array of its values, is written as the format writes a row, as `#writer(:array)` writes it,
    #   in the columns of the header row of the slice, or without one in the order of the fields of the schema, and a
    #   record of a slice of JSON, a Hash, as the format writes a record, see #parsed_lines.
    #   `validate: true` also parses each row before it is written. The text of each row of a slice of `:text` is
    #   written as one row of the file, as `#writer(:array)` writes it, see `IOStreams::Tabular#written_line`.
    # - Any other slice, such as one of CSV written to JSON, of a file without a header row written to one with one, or
    #   of the rows of an Active Record query, is read by its own header row and format, by the schema of the stream,
    #   reading the text of the cells of a slice that holds them as cells do,
    #   and each of its rows is written as `#writer(:array)` writes it, see `IOStreams::Row::Writer`, apart from a blank
    #   row, which a copy skips too.
    #
    # When no slice is written, the file holds the header row of the schema, as `#writer(:array)` writes it, see #finish.
    class Writer
      # Returns [Array<Symbol>] the options of each call that writes slices, see `IOStreams::Stream#writer`, which raises
      # for any other: those of the lines that it writes, see `IOStreams::Line::Writer.option_names`, and whether to
      # parse each row, see #initialize.
      def self.option_names
        [*IOStreams::Line::Writer.option_names, :validate]
      end

      # Raises ArgumentError for a `validate` that is not true or false, so that a call raises before the file is opened,
      # see `IOStreams::Slice::Collector.check_validate`.
      def self.check(validate: false)
        Collector.check_validate(validate)
      end

      # Parameters
      #   output: [#<<]
      #     Writes the lines of the file, or for a format whose rows are not lines, such as Parquet, its rows, see
      #     `IOStreams::Tabular#write_rows`.
      #
      #   tabular: [IOStreams::Tabular]
      #     Writes the rows in the format of the file, by its schema, and reads the rows of each slice by it, see
      #     `IOStreams::Tabular#for_format`.
      #
      #   validate: [true|false]
      #     Whether to parse each row of a slice that is written as it is before it is written, so that a row that the
      #     format or the schema cannot read raises before it is written. The rows of any other slice are always parsed.
      #     Default: false
      #
      # The caller checks the options before the file is opened, see .check.
      def initialize(output, tabular:, validate: false)
        @output   = output
        @tabular  = tabular
        @validate = validate
        @first    = nil
      end

      # Writes the rows of the supplied slice, after the header row, once, before the rows of the first slice.
      #
      # Returns self, so that calls can be chained.
      #
      # Raises ArgumentError for a slice of another file than the first one written, see `IOStreams::Slice#same_file?`:
      # with another header row or format, or that differs in whether its blank rows are records, whether its values
      # are the cells of a source of typed values, or its schema, since one reader reads the rows of every slice, see
      # #start.
      def <<(slice)
        raise(ArgumentError, "Write an IOStreams::Slice, not a #{slice.class.name}") unless slice.is_a?(Slice)

        if @first
          @first.send(:check_same_file, slice, "Every slice written is of the same file as the first")
        else
          start(slice)
        end
        @as_is ? write_as_is(slice) : write_rows(slice)
        self
      end

      alias write <<

      # Writes the header row of the schema when no slice was written, as `#writer(:array)` writes it, see
      # `IOStreams::Tabular#start_rows`, so that a file whose slices held no rows still has its header row. Called once
      # every slice has been written.
      def finish
        @tabular.start_rows { |line| @output << line } unless @first
      end

      # Returns [String] the class and the format of the file, rather than every instance variable, such as the tabular
      # and the lines that it writes.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect}>"
      end

      private

      # Decides how the slices are written, by the first one, see the class, and reads its header row, which is written
      # once, before its rows.
      def start(slice)
        @first  = slice
        @reader = @tabular.for_format(slice.format, headerless: !slice.header?, blank_rows: slice.blank_rows?,
                                                    typed: slice.typed?, cell_text: slice.cell_text?)
        @as_is  = @tabular.lines? && slice.format == @tabular.format && slice.header? == @tabular.requires_header? &&
                  !slice.cell_text?
        @reader.read_declared { slice.schema }
        @as_is ? start_as_is(slice) : start_rows(slice)
      end

      # Matches the header row of the slice, when it carries one, to the fields of the schema, and writes it as it was
      # read, without cleansing it, with a tabular of the format without a schema, which then writes each row of the
      # slices that is already parsed in its columns, see #parsed_lines.
      def start_as_is(slice)
        return unless slice.header?

        @reader.read_line(slice.header) { nil }
        @header_tabular = IOStreams::Tabular.new(format: @tabular.format)
        @header_tabular.render_row(slice.header) { |line| @output << line }
      end

      # Writes the header row of the rows read, see #write_rows, once it checks that the file can take their columns, see
      # `IOStreams::Tabular#check_unnamed_rows`.
      def start_rows(slice)
        @tabular.check_unnamed_rows if @reader.unnamed_columns?
        @rows = IOStreams::Row::Writer.new(@output, tabular: @tabular)
        @reader.read_row(slice.header) { |parsed| @rows << parsed } if slice.header?
      end

      # Writes each row of the slice as it is, see `IOStreams::Tabular#read_line`, which matches the keys of the first
      # record of a format of keyed records, such as JSON, to the fields of the schema, as the line that the file writes
      # for it, see `IOStreams::Tabular#written_line`, so that the text of a row of `:text` that holds a line break, such
      # as the CSV text of a row of a spreadsheet, is one line of a file of plain text, as `#writer(:array)` writes it.
      #
      # A row that is not a line, nor nil, a blank row, is already parsed, and is written as the format writes it, see
      # #parsed_lines.
      #
      # An `IOStreams::Errors::RowError` of a row names the record that it is and the line that it starts on: one that
      # its keys, or `validate: true`, raise, and the `IOStreams::Errors::TypeMismatch` of a row of `:text` that is not
      # one row of the format of the file, such as CSV whose quote is not closed, since it is the row that cannot be
      # written. A failure of the output that the line is written to is not a row's.
      def write_as_is(slice)
        slice.each do |row, line_number, record_number|
          # Rescued here, rather than in `IOStreams::Row::Locator.locate`, whose block would cost each row more. Every
          # row is a record, since the header row was read before the first, see #start_as_is, so the reader yields it.
          begin
            text = @reader.read_line(row) do |line|
              @reader.validate_line(line) if @validate
              line.nil? || line.is_a?(::String) ? @tabular.written_line(line) : parsed_lines(line)
            end
          rescue IOStreams::Errors::RowError => e
            raise e.at(line_number: line_number, record_number: record_number)
          end
          text.is_a?(::Array) ? text.each { |line| @output << line } : @output << text
        end
      end

      # Returns [Array<String>] the lines of a row of a slice of lines that is already parsed, rather than a line, such as
      # one that a program stored in a slice of CSV, as the format writes a row, see `IOStreams::Tabular#render_row`: an
      # Array of its values in the columns of the header row of the slices, by the tabular that wrote it, see
      # #start_as_is, or of a slice without one, in the order of the fields of the schema, and a Hash, a record of JSON,
      # by its keys, see `IOStreams::Tabular#render_record`, so that #write_as_is writes them outside of its rescue.
      #
      # Raises ArgumentError for an Array without a header row, or a schema, that names its columns, such as a row of a
      # slice of JSON written without a schema, rather than take it as the header row, see
      # `IOStreams::Tabular#check_unnamed_rows`.
      def parsed_lines(row)
        lines = []
        if row.is_a?(::Hash)
          @tabular.render_record(row) { |line| lines << line }
        elsif @header_tabular
          @header_tabular.render_row(row) { |line| lines << line }
        else
          @tabular.check_unnamed_rows
          @tabular.render_row(row) { |line| lines << line }
        end
        lines
      end

      # Reads each row of the slice, after the header row of the first one, see #start_rows, and
      # `IOStreams::Tabular#read_row`, and writes it, see `IOStreams::Row::Writer`. The rows of a format of keyed
      # records, such as JSON without a schema, are read by the keys of the first record of the first slice, which
      # raises `IOStreams::Errors::InvalidHeader` for a key that it lacked. An `IOStreams::Errors::RowError` of a row
      # that cannot be read names the record that it is and the line that it starts on, while the writer writes it
      # outside, so that an error that writing it raises is not taken for one of reading it.
      def write_rows(slice)
        slice.each do |row, line_number, record_number|
          header = nil
          parsed = nil
          # Rescued here, rather than in `IOStreams::Row::Locator.locate`, whose block would cost each row more.
          begin
            # The header row of the rows, the keys of the first record of a format of keyed records without a schema.
            @reader.read_row(row) do |each_row|
              if each_row.is_a?(IOStreams::Row::HeaderRow)
                header = each_row
              else
                parsed = each_row
              end
            end
          rescue IOStreams::Errors::RowError => e
            raise e.at(line_number: line_number, record_number: record_number)
          end
          @rows << header if header
          @rows << parsed unless parsed.nil?
        end
      end
    end
  end
end
