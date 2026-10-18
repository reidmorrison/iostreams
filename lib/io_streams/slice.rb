# frozen_string_literal: true

module IOStreams
  # A slice of the rows of a file, as they are in the file, which `IOStreams::Stream#each(:slice)` yields, such as up to
  # 100 lines of a CSV file, without its header row. Each slice can be parsed on its own, elsewhere, such as by another
  # process, or a worker on another machine, since it carries the header row of its file: a Tabular with the same
  # format and schema reads it, then parses each row by its columns:
  #
  #   IOStreams.path("people.csv").schema("people.json").each(:slice, size: 100) { |slice| queue << slice }
  #
  #   # Elsewhere:
  #   tabular = IOStreams::Tabular.new(format: :csv, schema: schema)
  #   tabular.read_header(slice.header) if slice.header
  #   slice.each { |line| process(tabular.record_parse(line)) }
  #
  # It is an Array of the rows: lines of text for a format of lines, such as CSV, including a blank line, which a
  # Tabular parses as nil, or for a format whose rows are not lines, such as Parquet, the rows that its reader returns,
  # see `IOStreams::Tabular#read_rows`. The methods of an Array that return a new Array, such as `map`, return an Array
  # rather than a slice.
  class Slice < ::Array
    autoload :Reader, "io_streams/slice/reader"

    # Returns [Array<String>] the header row of the file, as it was read, before it was cleansed or matched to the
    # fields of a schema, see `IOStreams::Tabular#header_row`, which every slice of the file shares, so it is frozen.
    # Returns nil when the file has no header row, such as fixed width, JSON, or a schema whose `header` is false.
    attr_reader :header

    def initialize(rows = [], header: nil)
      super(rows)
      @header = header
    end
  end
end
