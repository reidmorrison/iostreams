# frozen_string_literal: true

module IOStreams
  # A slice of the rows of a file, as they are in the file, which `IOStreams::Stream#each(:slice)` yields, such as up to
  # 100 lines of a CSV file, without its header row, so that its rows can be parsed elsewhere, such as by another thread,
  # process, or job. It describes its rows: the header row of their file, and the tabular format that they are parsed
  # in, so that whoever parses them does not need to know how the file was read.
  #
  #   IOStreams.path("people.csv.gz").schema("people.json").each(:slice, size: 100) { |slice| queue << slice }
  #
  # It is an Array of the rows: lines of text for a format of lines, such as CSV, including a blank line, or for a
  # format whose rows are not lines, such as Parquet, the rows that its reader returns. The methods of an Array that
  # return a new Array, such as `map`, return an Array rather than a slice.
  #
  # A slice does not name the file, nor its streams, such as `.gz` or `.enc`: they were applied when the file was read,
  # so its rows are text in its format.
  class Slice < ::Array
    autoload :Reader, "io_streams/slice/reader"

    # Returns [Array<String>] the header row of the file, as it was read, before it was cleansed or matched to the
    # fields of a schema, which every slice of the file shares, so it is frozen, as are its columns.
    # Returns nil when the file has no header row, such as fixed width, JSON, or a schema whose `header` is false.
    attr_reader :header

    # Returns [Symbol] the tabular format of the rows, such as `:csv`, see `IOStreams.tabular_formats`.
    attr_reader :format

    def initialize(rows = [], header: nil, format: nil)
      super(rows)
      @header = header
      @format = format
    end
  end
end
