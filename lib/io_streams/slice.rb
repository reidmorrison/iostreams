# frozen_string_literal: true

module IOStreams
  # A slice of the rows of a file, as they are in the file, which `IOStreams::Stream#each(:slice)` yields, such as up to
  # 100 lines of a CSV file, without its header row. Each slice can be parsed on its own, elsewhere, such as by another
  # process, or a worker on another machine, since it describes its rows: their format, the header row of their file,
  # and the line of the file that its first row is on. A pipeline set up once with the schema parses each slice, see
  # `IOStreams.sliced`:
  #
  #   IOStreams.path("people.csv.gz").schema("people.json").each(:slice, size: 100) { |slice| queue << slice }
  #
  #   # Elsewhere, once:
  #   sliced = IOStreams.sliced.schema(IOStreams.schema("people.json"))
  #   # Then for each slice:
  #   rows = sliced.slice(slice)
  #   rows.each(:hash) { |person| process(person, rows.line_number) }
  #
  # It is an Array of the rows: lines of text for a format of lines, such as CSV, including a blank line, which is
  # parsed as nil, or for a format whose rows are not lines, such as Parquet, the rows that its reader returns, see
  # `IOStreams::Tabular#read_rows`. The methods of an Array that return a new Array, such as `map`, return an Array
  # rather than a slice.
  #
  # A slice does not name the file, nor its streams, such as `.gz` or `.enc`: they were applied when the file was read,
  # so its rows are text in the format that they are parsed in.
  class Slice < ::Array
    autoload :Pipeline, "io_streams/slice/pipeline"
    autoload :Reader, "io_streams/slice/reader"
    autoload :Rows, "io_streams/slice/rows"
    autoload :Serializer, "io_streams/slice/serializer"

    # Returns [Array<String>] the header row of the file, as it was read, before it was cleansed or matched to the
    # fields of a schema, see `IOStreams::Tabular#header_row`, which every slice of the file shares, so it is frozen.
    # Returns nil when the file has no header row, such as fixed width, JSON, or a schema whose `header` is false.
    attr_reader :header

    # Returns [Integer] the number of the line of the file that the first row of this slice is on, counting from 1, so
    # that a failure to parse or process a row can name its line in the file, see `IOStreams::Slice::Rows#line_number`.
    # A row that holds a quoted line break spans more than one line. For a format whose rows are not lines, such as
    # Parquet, the number of its first row. Returns nil when it is not known.
    attr_reader :line_number

    # Returns [Symbol] the tabular format of the rows, such as `:csv`, in which they are parsed, see
    # `IOStreams.tabular_formats`, or nil when it is not known.
    attr_reader :format

    def initialize(rows = [], header: nil, line_number: nil, format: nil)
      super(rows)
      @header      = header
      @line_number = line_number
      @format      = format
    end

    # Returns [String] this slice as binary bytes, to store it or send it elsewhere, which `IOStreams.slice` reads back
    # as a slice, with its rows, header row, line number and format, so that whoever stores it keeps the bytes as they
    # are, without knowing what a slice holds. A pipeline also parses the bytes directly, see `IOStreams.sliced`.
    #
    # Parameters
    #   stream: [Symbol]
    #     The stream to write the slice through, such as `:zst`, `:gz` or `:bz2` to compress it, or `:enc` to encrypt it,
    #     which the bytes name, so that they are read back through it.
    #     Default: nil, which writes the slice as it is.
    #
    #   The other options are those of the stream, such as `level: 19` for `:zst`.
    #
    # Raises ArgumentError for a row that is not text, such as of Parquet, or not valid UTF-8, for a stream that is not
    # registered, and for options without a stream.
    #
    # Example:
    #   bytes = slice.serialize(stream: :zst)
    #   slice = IOStreams.slice(bytes)
    def serialize(stream: nil, **)
      Serializer.dump(self, stream: stream, **)
    end
  end
end
