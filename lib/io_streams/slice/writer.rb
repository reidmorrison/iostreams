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
    # Every slice is of the same file as the first one written: the same header row and format. The rows of every slice
    # are read by one reader, see `IOStreams::Tabular#for_format`, as the rows of one file, whether they start with a
    # header row being as the slice says, see `IOStreams::Slice#header?`, whatever the schema says of the file written.
    # The header row of the file is written once, before the rows of the first slice, and each row after it, in the
    # order written:
    # - A slice whose rows are lines of the format of the file, and that has a header row when the file has one, is
    #   written as it is, line for line, without parsing its rows, as `#each(:slice)` reads them, after its header row
    #   is matched to the fields of the schema, which raises `IOStreams::Errors::InvalidHeader` when they do not match.
    #   `validate: true` also parses each row before it is written. The text of each row of a slice of `:text` is
    #   written as one row of the file, as `#writer(:array)` writes it, see `IOStreams::Tabular#written_line`.
    # - Any other slice, such as one of CSV written to JSON, of a file without a header row written to one with one, or
    #   of the rows of an Active Record query, is read by its own header row and format, by the schema of the stream,
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
      # Raises ArgumentError for a slice of another file than the first one written: with another header row or format.
      def <<(slice)
        raise(ArgumentError, "Write an IOStreams::Slice, not a #{slice.class.name}") unless slice.is_a?(Slice)

        @first ? check_same_file(slice) : start(slice)
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
        @reader = @tabular.for_format(slice.format, headerless: !slice.header?, blank_rows: slice.blank_rows?)
        @as_is  = @tabular.lines? && slice.format == @tabular.format && slice.header? == @tabular.requires_header?
        @as_is ? start_as_is(slice) : start_rows(slice)
      end

      # Matches the header row of the slice, when it carries one, to the fields of the schema, and writes it as it was
      # read, without cleansing it, with a tabular of the format without a schema.
      def start_as_is(slice)
        return unless slice.header?

        @reader.read_line(slice.header) { nil }
        IOStreams::Tabular.new(format: @tabular.format).render_row(slice.header) { |line| @output << line }
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
      def write_as_is(slice)
        slice.each do |row, _line_number, _record_number|
          @reader.read_line(row) do |line|
            @reader.validate_line(line) if @validate
            @output << @tabular.written_line(line)
          end
        end
      end

      # Reads each row of the slice, after the header row of the first one, see #start_rows, and
      # `IOStreams::Tabular#read_row`, and writes it, see `IOStreams::Row::Writer`. The rows of a format of keyed
      # records, such as JSON without a schema, are read by the keys of the first record of the first slice, which
      # raises `IOStreams::Errors::InvalidHeader` for a key that it lacked.
      def write_rows(slice)
        slice.each do |row, _line_number, _record_number|
          @reader.read_row(row) { |parsed| @rows << parsed unless parsed.nil? }
        end
      end

      def check_same_file(slice)
        return if slice.header == @first.header && slice.format == @first.format

        raise(ArgumentError, "Every slice written is of the same file as the first: a slice with the header row " \
                             "#{slice.header.inspect} and format #{slice.format.inspect} cannot follow one with " \
                             "#{@first.header.inspect} and #{@first.format.inspect}")
      end
    end
  end
end
