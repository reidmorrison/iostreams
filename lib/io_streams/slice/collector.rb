# frozen_string_literal: true

module IOStreams
  class Slice
    # Collects the rows of a file into slices, see `IOStreams::Slice`, as they are in the file, whether the rows are read
    # from a file, see `IOStreams::Slice::Reader`, or written, see `IOStreams::Slice::TargetStream`, so that both make
    # the same slices.
    #
    # The tabular reads the header row, and decides which row it is, see `IOStreams::Tabular#read_line`, so that the
    # header row is matched to the fields of the schema, and raises `IOStreams::Errors::InvalidHeader` when they do not
    # match, before the first slice is handed on. It is not a row of any slice: each slice carries it instead, see
    # `IOStreams::Slice#header`, with the format of the rows and whether their blank rows are records, which the tabular
    # says, see `IOStreams::Tabular#blank_rows?`.
    #
    # Each slice also holds the numbers of each of its rows, see `IOStreams::Slice#each`: the line of the file that it
    # starts on, which whoever adds the rows supplies when it knows it, and its record number, which whoever adds the
    # rows also supplies when it knows it, such as the rows of a slice, otherwise the collector counts it, from 1,
    # without the header row, as it builds the slices, see #add.
    class Collector
      # Marks a row whose record number is not known, see #add, which is numbered as the next record.
      NEXT_RECORD = Object.new.freeze
      private_constant :NEXT_RECORD

      # Raises ArgumentError for options that cannot collect slices, see #initialize, so that a call raises before
      # anything is opened: a `size` that is not a positive Integer, a `validate` that is not true or false, see
      # .check_validate, or a `resume_at` that is neither nil nor a positive Integer, see .check_resume_at.
      def self.check(size:, validate: false, resume_at: nil)
        unless size.is_a?(Integer) && size.positive?
          raise(ArgumentError, "Invalid size #{size.inspect}: supply the number of rows of each slice")
        end

        check_validate(validate)
        check_resume_at(resume_at)
      end

      # Raises ArgumentError for a `resume_at` that is neither nil nor a positive Integer, the number of the record that
      # the slices start at, see #initialize, which #add compares the number of each record with.
      def self.check_resume_at(resume_at)
        IOStreams::Utils.check_record_number(:resume_at, resume_at)
      end

      # Raises ArgumentError for a `validate` that is not true or false, which says whether to parse each row, see
      # #initialize, for a call that decides the size of its slices some other way, such as from its store, see
      # `IOStreams::Slice::TargetStream`.
      def self.check_validate(validate)
        return if [true, false].include?(validate)

        raise(ArgumentError, "Invalid validate #{validate.inspect}: supply true or false")
      end

      # Yields a collector of the rows that the block writes, and writes each of its slices to the supplied target, see
      # `IOStreams::Slice::Target#write_slice`, after its header row, see `IOStreams::Slice::Target#write_header`. The
      # last slice, of the rows written since the one before it, is written once the block finishes, or leaves early,
      # such as with `break`, but not when it raises, or its thread is killed, so that the rows of a failed write are
      # not handed on, see `IOStreams::Utils.finish_or_abort`.
      #
      # Returns the result of the block.
      def self.write(target, **)
        collector = new(on_header: ->(header) { target.write_header(header) }, **) { |slice| target.write_slice(slice) }
        Utils.finish_or_abort(finish: -> { collector.finish }) { yield collector }
      end

      # Returns [Integer] the number of rows collected, in every slice, and those before `resume_at`, which are in none:
      # not the header row, nor the blank lines before it.
      attr_reader :count

      # Parameters
      #   tabular: [IOStreams::Tabular]
      #     Reads the header row, see `IOStreams::Tabular#read_line`, and parses each row when `validate` is true.
      #
      #   size: [Integer]
      #     The number of rows of each slice, apart from the last, which holds the rows that are left.
      #
      #   validate: [true|false]
      #     Whether to parse each row before it is added to its slice, so that a row that the format or the schema
      #     cannot read, such as a value that is not of the type of its field, raises before the slice that holds it
      #     is handed on, see `IOStreams::Tabular#validate_line`. The slices before it have already been handed on. The
      #     slice still holds the row as it is in the file.
      #     Default: false
      #
      #   resume_at: [Integer|nil]
      #     The number of the record that the slices start at, such as to resume the work of a job that processed the
      #     slices before it: the rows of the records before it are counted, so that the rows from it on keep their
      #     record numbers, but are not parsed, nor added to a slice.
      #     Default: nil, every row
      #
      #   on_header: [Proc]
      #     Called once with the header row of the file, as it was read, see #header, as soon as it has been read, and
      #     matched to the fields of the schema, before the first slice, also when the file has no rows after it. Not
      #     called for a file without a header row, see `IOStreams::Tabular#requires_header?`.
      #     Default: nil
      #
      # Yields [IOStreams::Slice] each slice, once it holds `size` rows, and the last one when #finish is called.
      #
      # The caller checks the options before anything is opened, see .check. `resume_at` is checked again, since #add
      # compares each record number with it.
      def initialize(tabular:, size:, validate: false, resume_at: nil, on_header: nil, &on_slice)
        self.class.check_resume_at(resume_at)
        @tabular   = tabular
        @size      = size
        @validate  = validate
        # The record that the slices start at, the first unless `resume_at` says otherwise: the records before it are
        # counted, but not collected.
        @resume_at = resume_at || 1
        @on_slice  = on_slice
        @on_header = on_header if tabular.requires_header?
        @slice     = nil
        @count     = 0
        # The record number of the last row added, see #add.
        @record_number = 0
      end

      # Adds the supplied row of the file, as the format holds it: a line of text, or for a format whose rows are not
      # lines, such as Parquet, the row that its reader returns. The header row is read instead, see
      # `IOStreams::Tabular#read_line`. A nil line is a blank line, as a writer of lines writes it.
      #
      # Parameters, all positional
      #   row: [String|Array|Hash|nil]
      #     The row to add.
      #
      #   line_number: [Integer|nil]
      #     The number of the line of the file that the row starts on, when whoever adds the rows knows it, see
      #     `IOStreams::Slice#line_number_at`.
      #     Default: nil, a row that is not a line of a file.
      #
      #   record_number: [Integer|nil]
      #     The record number of the row, when whoever adds the rows knows the numbers of their rows, such as the rows of
      #     a slice, so that the slices read from a slice keep them, see `IOStreams::Slice::Stream`: nil for a row that
      #     has none, such as a row that was added to a slice without numbers, see `IOStreams::Slice#add`.
      #     Default: the next record, counting from 1 without the header row, for rows whose numbers are not known, such
      #     as the lines of a file.
      #
      # The row is numbered by its record number, see `IOStreams::Slice#record_number_at`. A record before `resume_at`
      # is only counted, see #initialize.
      #
      # Returns self, so that calls can be chained.
      def add(row, line_number = nil, record_number = NEXT_RECORD)
        line = row.nil? ? "" : row
        return skip if record_number.equal?(NEXT_RECORD) && @record_number + 1 < @resume_at && !@tabular.header?

        @tabular.read_line(line) do |text|
          number         = record_number.equal?(NEXT_RECORD) ? @record_number + 1 : record_number
          @record_number = number if number
          @count        += 1
          @tabular.validate_line(text) if @validate
          @slice ||= Slice.new(header: header, format: @tabular.format, blank_rows: @tabular.blank_rows?)
          @slice.add(text, line_number: line_number, record_number: number)
          flush if @slice.size >= @size
        end
        header_read if @on_header
        self
      end

      alias << add
      alias write add

      # Returns [Array<String>] the header row of the file, as it was read, once it has been read, which every slice
      # carries, see `IOStreams::Slice#header`.
      # Returns nil until then, or when the file has no header row.
      def header
        @tabular.header_row
      end

      # Hands on the slice of the rows added since the last one, when there are any.
      def finish
        flush
      end

      # Returns [String] the class, the format of the rows and the size of the slices, rather than every instance
      # variable, such as the tabular and the slice that it collects.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect} size=#{@size}>"
      end

      private

      # Counts a record before `resume_at`, see #initialize, which it skips without parsing it, nor checking its keys: a
      # line is a record once the tabular no longer expects the header row, see `IOStreams::Tabular#header?`.
      #
      # Returns self.
      def skip
        @record_number += 1
        @count         += 1
        self
      end

      # Calls `on_header` with the header row, once it has been read, see #initialize.
      def header_read
        header = self.header
        return if header.nil?

        on_header  = @on_header
        @on_header = nil
        on_header.call(header)
      end

      def flush
        return unless @slice

        slice  = @slice
        @slice = nil
        @on_slice.call(slice)
      end
    end
  end
end
