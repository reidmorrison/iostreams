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
    # A slice holds rows, already split and decoded, rather than bytes, and is only read, see `IOStreams::Row::Stream`.
    class Stream < IOStreams::Row::Stream
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

      private

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
      def tabular(**)
        super(blank_rows: io_stream.blank_rows?, **)
      end

      # Yields [Numbered] the rows of the slice, after its header row, when it carries one, with the line number and
      # record number of each one, which a slice reader reads, see `IOStreams::Row::Stream#open_slice_rows`, so that the
      # slices that it reads from this slice keep the numbers of their rows, see `IOStreams::Slice#each`.
      def open_slice_rows(_tabular, _delimiter, _buffer_size)
        yield Numbered.new(io_stream)
      end

      # Returns [#each] the rows of the slice, after its header row, when it carries one, which the readers of rows and
      # records read as the header row of a file, see `IOStreams::Tabular#read_header`.
      def rows
        slice = io_stream
        Enumerator.new do |rows|
          rows << slice.header if slice.header
          slice.each { |row, _line_number, _record_number| rows << row }
          slice.size + (slice.header ? 1 : 0)
        end
      end

      # The rows of a slice, after its header row, when it carries one, with the line number and record number of each
      # one, see `IOStreams::Slice#each`, which a slice reader reads, see `IOStreams::Slice::Reader`, so that the slices
      # that it reads from them keep their numbers.
      class Numbered
        def initialize(slice)
          @slice = slice
        end

        # Yields the header row, which has no numbers, and then each row with its line number and record number.
        def each_with_numbers(&)
          header = @slice.header
          yield(header, nil, nil) if header
          @slice.each(&)
        end
      end
      private_constant :Numbered
    end
  end
end
