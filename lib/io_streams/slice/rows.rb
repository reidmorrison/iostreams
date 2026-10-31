# frozen_string_literal: true

module IOStreams
  class Slice
    # The rows that a slice reader reads, see `IOStreams::Slice::Reader`, when they are not lines of a file, see
    # `IOStreams::Slice::LineRows`, so that they start on no line: the records of a format such as Parquet, the rows of
    # an Active Record query, or the lines of text that a stream turns the data of a file into, such as the CSV text of a
    # spreadsheet, see `IOStreams::Builder#lines_of_file?`.
    class Rows
      # Parameters
      #   rows: [#each]
      #     Yields each row, such as those of a query, which can start with a header row.
      def initialize(rows)
        @rows = rows
      end

      # Yields each row with no line number, nil, since the rows are not lines of a file. Each row is yielded as one
      # value, also an Array, such as a row of a query.
      #
      # Returns the result of the `#each` of the rows.
      def each
        @rows.each { |row| yield(row, nil) }
      end

      # Returns [IOStreams::Schema|nil] the schema that the rows declare, when their reader declares one, such as that of
      # a Parquet file, see `IOStreams::Parquet::Reader#declared_schema`, which the slices of them carry, see
      # `IOStreams::Slice#schema`, or nil.
      def declared_schema
        @rows.declared_schema if @rows.respond_to?(:declared_schema)
      end
    end
  end
end
