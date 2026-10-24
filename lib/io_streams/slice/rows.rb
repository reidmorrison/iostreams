# frozen_string_literal: true

module IOStreams
  class Slice
    # The rows that a slice reader reads, see `IOStreams::Slice::Reader`, when they are not lines of a file, see
    # `IOStreams::Slice::LineRows`, so that they start on no line: the records of a format such as Parquet, the rows of
    # an Active Record query, or the lines of text that a stream turns the data of a file into, such as the CSV text of a
    # spreadsheet, see `IOStreams::Builder#lines_of_file?`. The collector numbers each of them as the next record, see
    # `IOStreams::Slice#record_number_at`.
    class Rows
      # Parameters
      #   rows: [#each]
      #     Yields each row, such as those of a query, which can start with a header row.
      def initialize(rows)
        @rows = rows
      end

      # Adds each row to the supplied collector, see `IOStreams::Slice::Collector#add`, without a line, since the rows
      # are not lines of a file.
      #
      # Returns the result of the `#each` of the rows.
      def add_to(collector)
        @rows.each { |row| collector.add(row) }
      end
    end
  end
end
