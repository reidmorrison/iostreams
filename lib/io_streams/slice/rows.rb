# frozen_string_literal: true

module IOStreams
  class Slice
    # The rows that a slice reader reads, see `IOStreams::Slice::Reader`, when they are not lines that a line reader
    # reads from a file, see `IOStreams::Line::Reader#each_with_line_number`, so that they start on no line: the records
    # of a format such as Parquet, or the rows of an Active Record query. The slices number each of them as the next
    # record, see `IOStreams::Slice#record_number_at`.
    class Rows
      # Parameters
      #   rows: [#each]
      #     Yields each row, after the header row when one is supplied.
      #
      #   header: [Array<String>]
      #     The header row, yielded before the rows.
      #     Default: nil, no header row is yielded before the rows, though they can start with one, such as those of a
      #     query.
      def initialize(rows, header: nil)
        @rows   = rows
        @header = header
      end

      # Yields each row with the line of the file that it starts on: nil, since the rows are not lines.
      #
      # Returns the result of the `#each` of the rows.
      def each_with_line_number
        yield(@header, nil) if @header
        @rows.each { |row| yield(row, nil) }
      end
    end
  end
end
