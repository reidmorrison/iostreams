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
    # A slice in the `:none` format, or without a format, holds its rows as they are, such as the slices of a store of
    # slices that is not given a format, see `IOStreams::Slice::TargetStream`, so its rows are read as they are, in the
    # `:array` and `:hash` modes, and in the `:slice` mode, in slices of their own, unless a format is set with #format,
    # in which the rows are read as the lines of that format:
    #
    #   IOStreams.stream(slice).each(:array) { |row| p row }
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
        "#<#{self.class.name} rows=#{io_stream.size} format=#{(format || :none).inspect}>"
      end

      # Yields the reader of the supplied mode, see `IOStreams::Stream#reader`. The rows of a slice in the `:none` format,
      # or without a format, unless one is set, are read as they are, see above: in the `:array` and `:hash` modes, each
      # row, whatever it is, apart from its header row, and nil when `skip_blanks:` is false, and in the `:slice` mode,
      # slices of `size:` rows of their own, with the header row of the slice, and the line of each row, whose records
      # are numbered from 1 again, as for the slices read from any slice.
      #
      # Raises ArgumentError for an option that the mode does not take, and for `validate: true` in the `:slice` mode,
      # since the rows are not parsed.
      def reader(mode = :stream, **args, &block)
        return super if %i[stream line].include?(mode) || !rows_as_they_are?

        require_block!(:reader, block)
        reject_lines!(**args)
        case mode
        when :array, :hash
          reject_unknown_options!(mode, mode == :array ? IOStreams::Row::Reader : IOStreams::Record::Reader, args)
          skip_blanks = args.fetch(:skip_blanks, false)
          IOStreams::Utils.check_boolean(:skip_blanks, skip_blanks)
          block.call(RowsAsTheyAre.new(io_stream, skip_blanks))
        when :slice
          reject_unknown_options!(mode, IOStreams::Slice::Reader, args)
          Collector.check(size: args[:size], validate: args.fetch(:validate, false))
          if args[:validate]
            raise(ArgumentError,
                  "The rows of a slice in the :none format are not parsed, so validate: is false")
          end

          block.call(SlicesAsTheyAre.new(io_stream, args[:size]))
        else
          super
        end
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
      # Returns nil for a slice in the `:none` format, so that a format can be set to read its rows in, see #reader.
      def text_format
        io_stream.format unless io_stream.format == :none
      end

      # Returns [true|false] whether the rows of the slice are read as they are, see #reader: when it is in the `:none`
      # format, or has none, and no other format is set.
      def rows_as_they_are?
        [nil, :none].include?(format)
      end

      # Returns [IOStreams::Tabular] that reads the rows of the slice, see `IOStreams::Stream#tabular`, reading a row
      # whose every value is blank as the slice says, see `IOStreams::Slice#blank_rows?`, so that a row of a query whose
      # every value is null is a record wherever its slice is read, as it is where the query is read.
      def tabular(**)
        super(blank_rows: io_stream.blank_rows?, **)
      end

      # Yields [RowsWithLines] the rows of the slice, after its header row, when it carries one, with the line of the file
      # that each one starts on, which a slice reader reads, see `IOStreams::Row::Stream#open_slice_rows`, so that the
      # slices that it reads from this slice keep the lines of their rows, see `IOStreams::Slice#line_number_at`. The
      # slice reader numbers their records as it builds the slices, see `IOStreams::Slice::Collector#add`.
      def open_slice_rows(_tabular, _delimiter, _buffer_size)
        yield RowsWithLines.new(io_stream)
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

      # The rows of a slice, after its header row, when it carries one, with the line of the file that each one starts
      # on, see `IOStreams::Slice#each`, which a slice reader reads, see `IOStreams::Slice::Reader`, so that the slices
      # that it reads from them keep their lines.
      class RowsWithLines
        def initialize(slice)
          @slice = slice
        end

        # Yields the header row, which starts on no line, nil, and then each row with its line number.
        def each
          header = @slice.header
          yield(header, nil) if header
          @slice.each { |row, line_number, _record_number| yield(row, line_number) }
        end
      end
      private_constant :RowsWithLines

      # Reads the rows of a slice as they are, see #reader, apart from its header row.
      class RowsAsTheyAre
        include Enumerable

        def initialize(slice, skip_blanks)
          @slice       = slice
          @skip_blanks = skip_blanks
        end

        # Yields each row, leaving out nil when `skip_blanks` is true.
        # Returns an Enumerator of them without a block.
        def each
          return enum_for(:each) unless block_given?

          @slice.each { |row| yield(row) unless @skip_blanks && row.nil? }
        end

        # Writes each row to the supplied writer of a copy, see `IOStreams::Stream#copy_from`, leaving out nil, as a copy
        # does, and the header row first, when the slice holds one.
        def copy_to(writer)
          writer.write_header(@slice.header) if @slice.header && writer.respond_to?(:write_header)
          @slice.each { |row| writer << row unless row.nil? }
        end
      end
      private_constant :RowsAsTheyAre

      # Reads the rows of a slice as they are, see #reader, in slices of their own of up to the supplied number of rows,
      # with the header row of the slice, and the line of each row, whose records are numbered from 1 again.
      class SlicesAsTheyAre
        include Enumerable

        def initialize(slice, size)
          @slice = slice
          @size  = size
        end

        # Yields each slice.
        # Returns an Enumerator of them without a block.
        def each(&block)
          return enum_for(:each) unless block

          collector = Collector.new(tabular: nil, size: @size, blank_rows: @slice.blank_rows?, &block)
          collector.write_header(@slice.header) if @slice.header
          @slice.each { |row, line_number, _record_number| collector.add(row, line_number) }
          collector.finish
        end
      end
      private_constant :SlicesAsTheyAre
    end
  end
end
