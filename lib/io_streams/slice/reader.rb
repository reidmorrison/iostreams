# frozen_string_literal: true

module IOStreams
  class Slice
    # Reads the rows of a file a slice at a time, see `IOStreams::Slice`, for `IOStreams::Stream#each(:slice)` and
    # `#reader(:slice)`, which create it with the rows of the file and the tabular of the stream.
    #
    # The tabular reads the header row, and decides which row it is, see `IOStreams::Tabular#read_line`, so that the
    # header row is matched to the fields of the schema, and raises `IOStreams::Errors::InvalidHeader` when they do not
    # match, before the first slice is yielded. It is not a row of any slice: each slice carries it instead, see
    # `IOStreams::Slice#header`, with the format of the rows and whether their blank rows are records, which the tabular
    # says, see `IOStreams::Tabular#blank_rows?`.
    class Reader
      include Enumerable

      # Returns [Array<Symbol>] the options of each call that reads slices, see `IOStreams::Stream#reader`, which raises
      # for any other: those of the lines that it reads, see `IOStreams::Row::Reader.line_option_names`, the number of
      # rows of each slice, and whether to parse each row, see #initialize.
      def self.option_names
        [*IOStreams::Row::Reader.line_option_names, :size, :validate]
      end

      # Raises ArgumentError for options that cannot read slices, see #initialize, so that a call raises before the file
      # is opened, see `IOStreams::Stream#each`: a `size` that is not a positive Integer, or a `validate` that is not true
      # or false, see `IOStreams::Slice::Collector.check`.
      def self.check(size:, validate: false)
        Collector.check(size: size, validate: validate)
      end

      # Parameters
      #   rows: [#each]
      #     Yields each row of the file, as the format holds it: a line of text, or for a format whose rows are not
      #     lines, such as Parquet, the row that its reader returns, see `IOStreams::Tabular#read_rows`. A line reader,
      #     see `IOStreams::Line::Reader`, also gives the line that each row starts on, which the slice of the first
      #     row holds, see `IOStreams::Slice#line_number`.
      #
      #   tabular: [IOStreams::Tabular]
      #     Reads the header row, see `IOStreams::Tabular#read_line`, and parses each row when `validate` is true.
      #
      #   size: [Integer]
      #     The number of rows of each slice, apart from the last, which holds the rows that are left.
      #
      #   validate: [true|false]
      #     Whether to parse each row before it is added to its slice, so that a row that the format or the schema
      #     cannot read, such as a value that is not of the type of its field, raises before the slice that holds it
      #     is yielded, see `IOStreams::Tabular#record_parse`. The slices before it have already been yielded. The slice
      #     still holds the row as it is in the file.
      #     Default: false
      def initialize(rows, tabular:, size:, validate: false)
        self.class.check(size: size, validate: validate)
        raise(ArgumentError, "Rows must be a IOStreams::Line::Reader or implement #each") unless rows.respond_to?(:each)

        @rows     = rows
        @tabular  = tabular
        @size     = size
        @validate = validate
      end

      # Returns [Array<String>] the header row of the file, as it was read, once it has been read, which every slice
      # carries, see `IOStreams::Slice#header`, including when the file has no rows after it, so that no slice is
      # yielded.
      # Returns nil until then, or when the file has no header row.
      def header
        @tabular.header_row
      end

      # Yields each slice of the rows of the file, see `IOStreams::Slice`, after reading its header row, when it has one,
      # see `IOStreams::Slice::Collector`.
      #
      # Returns [Integer] the number of rows read, in every slice: not the header row, nor the blank lines before it.
      def each(&)
        collector = Collector.new(tabular: @tabular, size: @size, validate: @validate, &)
        if @rows.is_a?(IOStreams::Line::Reader)
          @rows.each { |row| collector.add(row, @rows.start_line_number) }
        else
          @rows.each { |row| collector << row }
        end
        collector.finish
        collector.count
      end

      # Returns [String] the class, the format of the rows and the size of the slices, rather than every instance
      # variable, such as the tabular and the rows that it reads, so that irb, which displays what a reader block
      # returns, shows what the documentation describes.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect} size=#{@size}>"
      end
    end
  end
end
