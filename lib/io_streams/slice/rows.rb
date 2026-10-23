# frozen_string_literal: true

module IOStreams
  class Slice
    # The rows that a slice reader reads, see `IOStreams::Slice::Reader`, when they are not lines that a line reader
    # reads from a file, see `IOStreams::Line::Reader#each_with_line_number`: the records of a format such as Parquet,
    # the rows of an Active Record query, or the rows of a slice, which give each row the line that it starts on as far
    # as they know it.
    class Rows
      # Parameters
      #   rows: [#each]
      #     Yields each row, after the header row when one is supplied.
      #
      #   header: [Array<String>]
      #     The header row, yielded before the rows, which starts on no line of its own.
      #     Default: nil, no header row is yielded before the rows, though they can start with one, such as those of a
      #     query.
      #
      #   line_number: [Integer]
      #     The line of the file that the first row starts on, such as the line of the first row of a slice, see
      #     `IOStreams::Slice#line_number`. Each row after it is numbered as the next line, which is its line unless a
      #     row before it holds the line endings of a quoted value.
      #     Default: nil, the rows are not lines, so that the slices number them by row, see
      #     `IOStreams::Slice::Collector#add`.
      def initialize(rows, header: nil, line_number: nil)
        @rows        = rows
        @header      = header
        @line_number = line_number
      end

      # Yields each row with the line of the file that it starts on, see #initialize, or nil when it has none: the
      # header row, and rows that are not lines.
      #
      # Returns the result of the `#each` of the rows.
      def each_with_line_number
        yield(@header, nil) if @header
        line_number = @line_number
        return @rows.each { |row| yield(row, nil) } unless line_number

        @rows.each do |row|
          yield(row, line_number)
          line_number += 1
        end
      end
    end
  end
end
