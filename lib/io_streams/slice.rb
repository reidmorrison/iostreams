# frozen_string_literal: true

module IOStreams
  # A slice of the rows of a file, as they are in the file, which `IOStreams::Stream#each(:slice)` yields, such as up to
  # 100 lines of a CSV file, without its header row, so that its rows can be parsed elsewhere, such as by another thread,
  # process, or job. It describes its rows: the header row of their file, and the tabular format that they are parsed
  # in, so that whoever parses them does not need to know how the file was read.
  #
  #   IOStreams.path("people.csv.gz").schema("people.json").each(:slice, size: 100) { |slice| queue << slice }
  #
  #   # Elsewhere, reading the schema file once, rather than once for each slice:
  #   schema = JSON.parse(IOStreams.path("people.json").read)
  #   IOStreams.stream(queue.pop).schema(schema).each(:hash) { |person| p person }
  #
  # It is an Array of the rows: lines of text for a format of lines, such as CSV, including a blank line, or for a
  # format whose rows are not lines, such as Parquet, the rows that its reader returns. The methods of an Array that
  # return a new Array, such as `map`, return an Array rather than a slice.
  #
  # A row whose every value is blank is a blank row, as in a file, unless each row of the slice is a record, such as a
  # slice of the rows of an Active Record query, see #blank_rows?.
  #
  # It also holds the number of the line of the file that its first row starts on, see #line_number, so that support
  # staff can find its rows in the file.
  #
  # A slice does not name the file, nor its streams, such as `.gz` or `.enc`: they were applied when the file was read,
  # so its rows are text in its format.
  #
  # To store a slice, or send it to another process, #to_h returns what it holds as a Hash, which `IOStreams.slice`
  # turns back into a slice.
  class Slice < ::Array
    autoload :Collector, "io_streams/slice/collector"
    autoload :Reader, "io_streams/slice/reader"
    autoload :Stream, "io_streams/slice/stream"
    autoload :Target, "io_streams/slice/target"
    autoload :TargetStream, "io_streams/slice/target_stream"
    autoload :Writer, "io_streams/slice/writer"

    # The keys of the Hash of a slice, see #to_h.
    KEYS = %w[rows header format blank_rows line_number].freeze

    # Returns [IOStreams::Slice] the slice that the supplied Hash describes, which #to_h returned, see `IOStreams.slice`.
    # Its keys can be Strings or Symbols, and its format a String or a Symbol, as storing it may have changed them. The
    # header row is a frozen copy, since every slice of a file shares it.
    #
    # Raises ArgumentError when it does not describe a slice: when it is not a Hash, has no rows, or a key that a slice
    # does not have, or when its rows are not an Array, its header row is not an Array of Strings, its format is not a
    # tabular format, see `IOStreams.tabular_formats`, its `blank_rows` is not true or false, or its `line_number` is
    # not a positive Integer.
    def self.from_h(hash)
      raise(ArgumentError, "A slice must be the Hash that #to_h returns, not #{hash.class.name}") unless hash.is_a?(::Hash)

      values  = hash.transform_keys(&:to_s)
      unknown = values.keys - KEYS
      unless unknown.empty?
        raise(ArgumentError, "Unknown #{unknown.size == 1 ? 'key' : 'keys'} #{unknown.map(&:inspect).join(', ')} of a " \
                             "slice. Valid keys: #{KEYS.map(&:inspect).join(', ')}")
      end

      new(rows_of(values["rows"]), header: header_of(values["header"]), format: format_of(values["format"]),
          blank_rows: blank_rows_of(values["blank_rows"]), line_number: line_number_of(values["line_number"]))
    end

    # Returns [Array] the rows of the Hash of a slice, see .from_h.
    def self.rows_of(rows)
      return rows if rows.is_a?(::Array)
      raise(ArgumentError, "The Hash of a slice has no rows") if rows.nil?

      raise(ArgumentError, "The rows of a slice must be an Array, not #{rows.class.name}")
    end
    private_class_method :rows_of

    # Returns [Array<String>] a frozen copy of the header row of the Hash of a slice, see .from_h, whose columns are
    # Strings, or nil for a column without a name, or nil for a slice without one.
    def self.header_of(header)
      return if header.nil?
      unless header.is_a?(::Array) && header.all? { |column| column.nil? || column.is_a?(::String) }
        raise(ArgumentError, "The header row of a slice must be an Array of Strings, or nil: #{header.inspect}")
      end

      Utils.frozen_copy(header)
    end
    private_class_method :header_of

    # Returns [Symbol] the tabular format of the Hash of a slice, see .from_h, or nil for a slice without one.
    def self.format_of(format)
      return if format.nil?

      name = format.to_sym if format.is_a?(::String) || format.is_a?(::Symbol)
      return name if IOStreams.tabular_formats.include?(name)

      raise(ArgumentError, "Unknown format of a slice: #{format.inspect}. Valid formats: " \
                           "#{IOStreams.tabular_formats.map(&:inspect).join(', ')}")
    end
    private_class_method :format_of

    # Returns [true|false] whether a row of the Hash of a slice whose every value is blank is a blank row, see .from_h
    # and #blank_rows?: true, as in a file, when the Hash does not say, since #to_h only holds it when it is false.
    def self.blank_rows_of(blank_rows)
      return true if blank_rows.nil?
      return blank_rows if [true, false].include?(blank_rows)

      raise(ArgumentError, "The blank_rows of a slice must be true or false: #{blank_rows.inspect}")
    end
    private_class_method :blank_rows_of

    # Returns [Integer] the line number of the Hash of a slice, see .from_h and #line_number, or nil for a slice without
    # one, such as one that an earlier version stored.
    def self.line_number_of(line_number)
      return line_number if line_number.nil? || (line_number.is_a?(::Integer) && line_number.positive?)

      raise(ArgumentError, "The line_number of a slice must be a positive Integer: #{line_number.inspect}")
    end
    private_class_method :line_number_of

    # Returns [Array<String>] the header row of the file, as it was read, before it was cleansed or matched to the
    # fields of a schema, which every slice of the file shares, so it is frozen, as are its columns.
    # Returns nil when the file has no header row, such as fixed width, JSON, or a schema whose `header` is false.
    attr_reader :header

    # Returns [Symbol] the tabular format of the rows, such as `:csv`, see `IOStreams.tabular_formats`.
    attr_reader :format

    # Returns [Integer] the number of the line of the file that the first row of this slice starts on, counting from 1,
    # as a text editor numbers it, so the header row and blank lines count, and a quoted value that holds line breaks
    # counts each of its lines. For instance 2 for the first slice of a CSV file whose header row is on line 1. Only
    # the first row has one: the position of a row within the slice is that of whoever processes it.
    #
    # For rows that are not lines of a file, such as those of a Parquet file, an Active Record query, or rows and
    # records written to a store of slices, see `IOStreams::Slice::TargetStream`, it is the number of the first row,
    # counting from 1, without the header row, so the next slice of 100 rows after one at 1 starts at 101.
    #
    # Returns nil for a slice built without one, see #initialize.
    attr_reader :line_number

    def initialize(rows = [], header: nil, format: nil, blank_rows: true, line_number: nil)
      super(rows)
      @header      = header
      @format      = format
      @blank_rows  = blank_rows
      @line_number = line_number
    end

    # Returns [true|false] whether a row whose every value is blank, such as a line of CSV of only commas, is a blank
    # row, read as nil, as in a file, see `IOStreams::Tabular::Mapping`, which the tabular that read the rows decided,
    # see `IOStreams::Tabular#blank_rows?`. False when each row is a record, whatever its values, such as the rows of an
    # Active Record query, see `IOStreams::Query::Stream`, so that the stream of the slice reads a row whose every value
    # is null as a record too, see `IOStreams::Slice::Stream`.
    def blank_rows?
      @blank_rows
    end

    # Returns [Hash] what this slice holds, to store it or send it elsewhere, such as in the document of a job, which
    # `IOStreams.slice` turns back into a slice: its rows, the header row of its file, the format of its rows, and the
    # line of its first row, see #line_number, when it has one, by String keys, with Strings, Integers, Arrays and nil,
    # as JSON and BSON hold them, so that it is the same once stored. When each of its rows is a record, see
    # #blank_rows?, it also holds `"blank_rows" => false`, which is otherwise left out. The rows of a format whose rows
    # are not lines, such as Parquet, are the records that its reader returned, whose values are only kept as they are
    # by a store that keeps their types.
    #
    # Example:
    #   slice.to_h
    #   # => {"rows" => ["Jack,21", "Jill,22"], "header" => ["Name", "AGE"], "format" => "csv",
    #   #     "line_number" => 2}
    def to_h
      hash = {"rows" => to_a, "header" => header, "format" => format&.to_s}
      hash["blank_rows"]  = false unless blank_rows?
      hash["line_number"] = line_number if line_number
      hash
    end
  end
end
