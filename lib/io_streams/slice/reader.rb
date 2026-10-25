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
    # says, see `IOStreams::Tabular#blank_rows?`, and the line number and record number of each row, see
    # `IOStreams::Slice#each`.
    class Reader
      include Enumerable

      # Returns [Array<Symbol>] the options of each call that reads slices, see `IOStreams::Stream#reader`, which raises
      # for any other: those of the lines that it reads, see `IOStreams::Row::Reader.line_option_names`, the number of
      # rows of each slice, whether to parse each row, and the record that reading resumes at, see #initialize.
      def self.option_names
        [*IOStreams::Row::Reader.line_option_names, :size, :validate, :resume_at]
      end

      # Raises ArgumentError for options that cannot read slices, see #initialize, so that a call raises before the file
      # is opened, see `IOStreams::Stream#each`: a `size` that is not a positive Integer, or a `validate` that is not true
      # or false, see `IOStreams::Slice::Collector.check`, or a `resume_at` that is neither nil nor a positive Integer.
      def self.check(size:, validate: false, resume_at: nil)
        Collector.check(size: size, validate: validate)
        IOStreams::Utils.check_record_number(:resume_at, resume_at)
      end

      # Parameters
      #   rows: [#each]
      #     Yields each row of the file, as the format holds it, starting with its header row, when it has one, with the
      #     line of the file that it starts on, when the rows know it, otherwise nil, and its record number, when the
      #     rows know it:
      #     - the lines of a file, see `IOStreams::Slice::LineRows`.
      #     - the rows of a slice, see `IOStreams::Slice::Stream`, so that they keep their lines and record numbers.
      #     - rows that are not lines of a file, such as those of Parquet, which start on no line, see
      #       `IOStreams::Slice::Rows`.
      #     The collector numbers each row by the record number that the rows give it, otherwise as the next record, as
      #     it builds the slices, see `IOStreams::Slice::Collector#add`.
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
      #     is yielded, see `IOStreams::Tabular#validate_line`. The slices before it have already been yielded. The slice
      #     still holds the row as it is in the file.
      #     Default: false
      #
      #   resume_at: [Integer|nil]
      #     The number of the record that reading resumes at, so that the first slice starts with it, such as to resume
      #     the work of a job that processed the slices before it, see `IOStreams::Slice::Collector#initialize`.
      #     Default: nil, every row
      def initialize(rows, tabular:, size:, validate: false, resume_at: nil)
        self.class.check(size: size, validate: validate, resume_at: resume_at)
        unless rows.respond_to?(:each)
          raise(ArgumentError, "Rows must implement #each, yielding each row with its line number, such as " \
                               "IOStreams::Slice::Rows")
        end

        @rows     = rows
        @tabular  = tabular
        @size     = size
        @validate = validate
        @resume_at = resume_at
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
      # Returns [Integer] the number of rows read, including those before `resume_at`, which are in no slice: not the
      # header row, nor the blank lines before it.
      # Returns an Enumerator of the slices without a block.
      def each(&)
        return enum_for(:each) unless block_given?

        collector = Collector.new(tabular: @tabular, size: @size, validate: @validate, resume_at: @resume_at, &)
        # The rows of a slice also give the record number of each row, which the collector keeps, see #initialize.
        @rows.each { |row, line_number, *record_number| collector.add(row, line_number, *record_number) }
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
