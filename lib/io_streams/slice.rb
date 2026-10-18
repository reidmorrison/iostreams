# frozen_string_literal: true

module IOStreams
  # A slice of the rows of a file, as they are in the file, which `IOStreams::Stream#each(:slice)` yields, such as up to
  # 100 lines of a CSV file, without its header row, so that its rows can be parsed elsewhere, such as by another thread,
  # process, or job. It describes its rows: the header row of their file, and the tabular format that they are parsed
  # in, so that whoever parses them does not need to know how the file was read.
  #
  #   IOStreams.path("people.csv.gz").schema("people.json").each(:slice, size: 100) { |slice| queue << slice }
  #
  #   # Elsewhere:
  #   IOStreams.stream(queue.pop).schema("people.json").each(:hash) { |person| p person }
  #
  # It is an Array of the rows: lines of text for a format of lines, such as CSV, including a blank line, or for a
  # format whose rows are not lines, such as Parquet, the rows that its reader returns. The methods of an Array that
  # return a new Array, such as `map`, return an Array rather than a slice.
  #
  # A slice does not name the file, nor its streams, such as `.gz` or `.enc`: they were applied when the file was read,
  # so its rows are text in its format.
  #
  # To store a slice, or send it to another process, #to_h returns what it holds as a Hash, which `IOStreams.slice`
  # turns back into a slice.
  class Slice < ::Array
    autoload :Reader, "io_streams/slice/reader"
    autoload :Stream, "io_streams/slice/stream"

    # The keys of the Hash of a slice, see #to_h.
    KEYS = %w[rows header format].freeze

    # Returns [IOStreams::Slice] the slice that the supplied Hash describes, which #to_h returned, see `IOStreams.slice`.
    # Its keys can be Strings or Symbols, and its format a String or a Symbol, as storing it may have changed them. The
    # header row is a frozen copy, since every slice of a file shares it.
    #
    # Raises ArgumentError when it does not describe a slice: when it is not a Hash, has no rows, or a key that a slice
    # does not have, or when its rows are not an Array, its header row is not an Array of Strings, or its format is not
    # a tabular format, see `IOStreams.tabular_formats`.
    def self.from_h(hash)
      raise(ArgumentError, "A slice must be the Hash that #to_h returns, not #{hash.class.name}") unless hash.is_a?(::Hash)

      values  = hash.transform_keys(&:to_s)
      unknown = values.keys - KEYS
      unless unknown.empty?
        raise(ArgumentError, "Unknown #{unknown.size == 1 ? 'key' : 'keys'} #{unknown.map(&:inspect).join(', ')} of a " \
                             "slice. Valid keys: #{KEYS.map(&:inspect).join(', ')}")
      end

      new(rows_of(values["rows"]), header: header_of(values["header"]), format: format_of(values["format"]))
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

    # Returns [Hash] what this slice holds, to store it or send it elsewhere, such as in the document of a job, which
    # `IOStreams.slice` turns back into a slice: its rows, the header row of its file, and the format of its rows, by
    # String keys, with Strings, Arrays and nil, as JSON and BSON hold them, so that it is the same once stored. The
    # rows of a format whose rows are not lines, such as Parquet, are the records that its reader returned, whose
    # values are only kept as they are by a store that keeps their types.
    #
    # Example:
    #   slice.to_h
    #   # => {"rows" => ["Jack,21", "Jill,22"], "header" => ["Name", "AGE"], "format" => "csv"}
    def to_h
      {"rows" => to_a, "header" => header, "format" => format&.to_s}
    end
  end
end
