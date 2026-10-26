# frozen_string_literal: true

module IOStreams
  class Slice
    # The stream of a slice, see `IOStreams::Slice`, which `IOStreams.stream(slice)` returns, so that the rows of a slice
    # are read as the rows of a file are, by the settings of the stream, such as #schema:
    #
    #   schema = JSON.parse(IOStreams.path("people.json").read) # Once, rather than once for each slice
    #   IOStreams.stream(slice).schema(schema).each(:hash) { |person| p person }
    #
    # Its rows start with the header row that the slice carries, which the tabular reads, see
    # `IOStreams::Tabular#read_header`, so that each row is read by the columns of the file that it came from, in the
    # format that the slice carries, see #format, and a row whose every value is blank is a blank row unless the slice
    # says that each of its rows is a record, see #tabular.
    #
    # The record numbers of the rows are those that the slice holds, see `IOStreams::Slice#record_number_at`: `resume_at:`
    # names one of them, see #reader, and the slices read from it keep them, as they keep the line of each row.
    #
    # A slice holds rows, already split and decoded, rather than bytes, and is only read, see `IOStreams::Row::Stream`.
    class Stream < IOStreams::Row::Stream
      # The modes whose readers resume at a record, see #reader.
      RESUMABLE_MODES = %i[array hash slice].freeze

      # Parameters
      #   slice: [IOStreams::Slice]
      #     The rows of the slice, its header row, and the format of its rows.
      def initialize(slice)
        raise(ArgumentError, "Not a slice: #{slice.class.name}, see IOStreams.stream") unless slice.is_a?(Slice)

        super
      end

      # Returns [String] the class, the number of rows and their format, rather than every instance variable, such as
      # the rows of the slice.
      def inspect
        "#<#{self.class.name} rows=#{io_stream.size} format=#{format.inspect}>"
      end

      # Yields the reader of the supplied mode, see `IOStreams::Row::Stream#reader`. `resume_at:` in the `:array`, `:hash`
      # and `:slice` modes is a record number that the slice holds, see `IOStreams::Slice#record_number_at`, such as
      # the one that a job saw when it stopped, rather than a count of the rows of the slice, so the rows are read from
      # that record on, see `IOStreams::Slice#from_record`, and the slices read from them keep their numbers.
      #
      # Raises ArgumentError for a `resume_at` that is neither nil nor a positive Integer, and for one that the slice
      # does not hold, other than the record after its last, which reads no rows, before any row is read.
      def reader(mode = :stream, **args, &)
        resume_at = args[:resume_at]
        return super if resume_at.nil? || !RESUMABLE_MODES.include?(mode)

        IOStreams::Utils.check_record_number(:resume_at, resume_at)
        from_record(resume_at).reader(mode, **args.except(:resume_at), &)
      end

      protected

      # Holds the supplied slice as the rows that this stream reads, see #from_record.
      def read_slice(slice)
        @io_stream = slice
      end

      private

      # Returns [IOStreams::Slice::Stream] a copy of this stream, with its settings, such as its schema, that reads the
      # rows of its slice from the record of the supplied number on, see `IOStreams::Slice#from_record`.
      def from_record(record_number)
        copy = dup
        copy.read_slice(io_stream.from_record(record_number))
        copy
      end

      def source_name
        "slice"
      end

      def rows_hint
        "iterate the slice for its rows as they are"
      end

      # Returns [Symbol|nil] the format that the slice carries, which its rows are in, see
      # `IOStreams::Stream#text_format`, so that #format returns it, and reading raises for another format that is set.
      def text_format
        io_stream.format
      end

      # Returns [IOStreams::Tabular] that reads the rows of the slice, see `IOStreams::Stream#tabular`, reading a row
      # whose every value is blank as the slice says, see `IOStreams::Slice#blank_rows?`, so that a row of a query whose
      # every value is null is a record wherever its slice is read, as it is where the query is read.
      #
      # The rows start with a header row only when the slice carries one, see `IOStreams::Slice#header?`, whatever the
      # format or the schema says of the file, so that the first row of a slice without one is never read as its header
      # row. Without a schema, nothing then names the columns of such a slice of a format with a header row, such as CSV,
      # so that its records cannot be read, see `IOStreams::Tabular#check_records`, while its rows can.
      #
      # The values of rows that are already those of the fields, see `IOStreams::Slice#typed?`, such as those written to
      # a store of slices in the `:hash` mode, are matched to the fields of the schema by their keys or header row, but
      # not converted again, so that they are read as they were written, or as the store keeps them.
      def tabular(**)
        super(blank_rows: io_stream.blank_rows?, headerless: !io_stream.header?, typed: io_stream.typed?, **)
      end

      # Yields [NumberedRows] the rows of the slice, after its header row, when it carries one, with the line of the file
      # that each one starts on and its record number, which a slice reader reads, see
      # `IOStreams::Row::Stream#open_slice_rows`, so that the slices that it reads from this slice keep the numbers of
      # their rows, see `IOStreams::Slice#each`.
      def open_slice_rows(_tabular, _delimiter, _buffer_size)
        yield NumberedRows.new(io_stream)
      end

      # Returns [#each] the rows of the slice, after its header row, when it carries one, which the readers of rows and
      # records read as the header row of a file, see `IOStreams::Tabular#read_header`.
      def rows
        slice = io_stream
        Enumerator.new do |rows|
          rows << slice.header if slice.header?
          slice.each { |row, _line_number, _record_number| rows << row }
          slice.size + (slice.header? ? 1 : 0)
        end
      end

      # The rows of a slice, after its header row, when it carries one, with the line of the file that each one starts
      # on and its record number, see `IOStreams::Slice#each`, which a slice reader reads, see
      # `IOStreams::Slice::Reader`, so that the slices that it reads from them keep their numbers.
      class NumberedRows
        def initialize(slice)
          @slice = slice
        end

        # Yields the header row, which is neither on a line nor a record, nil, nil, and then each row with its line
        # number and record number, see `IOStreams::Slice#each`.
        def each(&)
          yield(@slice.header, nil, nil) if @slice.header?
          @slice.each(&)
        end
      end
      private_constant :NumberedRows
    end
  end
end
