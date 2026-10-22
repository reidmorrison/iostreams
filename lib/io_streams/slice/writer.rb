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
    # Every slice is of the same file as the first one written: the same header row and format. The header row is
    # written once, before the rows of the first slice, and each row after it, in the order written:
    # - A slice whose rows are lines of the format of the file is written as it is, line for line, without parsing its
    #   rows, as `#each(:slice)` reads them, after its header row is matched to the fields of the schema, which raises
    #   `IOStreams::Errors::InvalidHeader` when they do not match. `validate: true` also parses each row before it is
    #   written.
    # - Any other slice, such as one of CSV written to JSON, or of the rows of an Active Record query, is read by its own
    #   header row and format, by the schema of the stream, and each of its rows is written as `#writer(:array)` writes
    #   it, see `IOStreams::Row::Writer`, apart from a blank row, which a copy skips too.
    class Writer
      # Returns [Array<Symbol>] the options of each call that writes slices, see `IOStreams::Stream#writer`, which raises
      # for any other: those of the lines that it writes, see `IOStreams::Line::Writer.option_names`, and whether to
      # parse each row, see #initialize.
      def self.option_names
        [*IOStreams::Line::Writer.option_names, :validate]
      end

      # Raises ArgumentError for a `validate` that is not true or false, so that a call raises before the file is opened.
      def self.check(validate: false)
        return if [true, false].include?(validate)

        raise(ArgumentError, "Invalid validate #{validate.inspect}: supply true or false")
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
      def initialize(output, tabular:, validate: false)
        self.class.check(validate: validate)

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

      # Returns [String] the class and the format of the file, rather than every instance variable, such as the tabular
      # and the lines that it writes.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect}>"
      end

      private

      # Decides how the slices are written, by the first one, see the class, and writes the header row of a slice that is
      # written as it is.
      def start(slice)
        @first  = slice
        @reader = reader_of(slice)
        @as_is  = @tabular.lines? && @reader.format == @tabular.format
        return @rows = IOStreams::Row::Writer.new(@output, tabular: @tabular) unless @as_is
        return unless slice.header

        @reader.read_line(slice.header) { nil }
        IOStreams::Tabular.new(format: @tabular.format).render_row(slice.header) { |line| @output << line }
      end

      # Writes each row of the slice as it is, see `IOStreams::Tabular#read_line`, which matches the keys of the first
      # record of a format of keyed records, such as JSON, to the fields of the schema.
      def write_as_is(slice)
        slice.each do |row|
          @reader.read_line(row) do |line|
            @reader.record_parse(line) if @validate
            @output << line
          end
        end
      end

      # Reads each row of the slice by its header row, see `IOStreams::Tabular#read_row`, and writes it, see
      # `IOStreams::Row::Writer`. The header row that each slice starts with is written once, for the first slice.
      def write_rows(slice)
        reader = slice.equal?(@first) ? @reader : reader_of(slice)
        first  = slice.equal?(@first)
        rows   = slice.header ? [slice.header].each.chain(slice) : slice.each
        rows.each do |row|
          reader.read_row(row) do |parsed|
            next if parsed.nil? || (!first && parsed.is_a?(IOStreams::Row::HeaderRow))

            @rows << parsed
          end
        end
      end

      # Returns [IOStreams::Tabular] that reads the rows of the slice, in its format, by the schema of the file, see
      # `IOStreams::Tabular#for_format`.
      def reader_of(slice)
        @tabular.for_format(slice.format, blank_rows: slice.blank_rows?)
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
