# frozen_string_literal: true

module IOStreams
  module Row
    # The header row that `IOStreams::Stream#each(:array)` yields before the rows of a file, which names the column of
    # each value of the rows after it. It is an Array, as every other row is, whose class says that it is the header
    # row, so that a writer of rows takes it as the header row of the rows written after it, rather than as a row of
    # values, see `IOStreams::Row::Writer#<<`, and so that code that reads the rows can tell it apart:
    #
    #   path.each(:array) do |row|
    #     next if row.is_a?(IOStreams::Row::HeaderRow)
    #
    #     process(row)
    #   end
    #
    # It is equal to an Array of the same columns, and the methods of an Array that return a new Array, such as `map`,
    # return an Array rather than a header row, so that a row made from it is a row of values.
    class HeaderRow < ::Array
    end
  end
end
