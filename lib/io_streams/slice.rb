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
  # It holds its rows: lines of text for a format of lines, such as CSV, including a blank line, or for a format whose
  # rows are not lines, such as Parquet, the rows that its reader returns. It also holds the numbers of each row, so
  # that support staff can find it in its file, see #each:
  # - its line number, the line of the file that it starts on, see #line_number_at, or nil for a row that is not a line
  #   of a file, such as a row of Parquet or of an Active Record query.
  # - its record number, the number of the row in its file, counting from 1 without the header row, see
  #   #record_number_at, so that a blank row counts too.
  #
  # A slice is responsible for its rows and their numbers, so it is not an Array: its rows are added to it, see #add,
  # changed, see #[]= and #delete_at, and read from it, see #each and #rows, through its own methods, which keep the
  # numbers of each row.
  #
  # A row whose every value is blank is a blank row, as in a file, unless each row of the slice is a record, such as a
  # slice of the rows of an Active Record query, see #blank_rows?.
  #
  # The values of its rows are read by a schema, see `IOStreams::Slice::Stream`, unless they are already those of the
  # fields of a schema, such as the rows and records written to a store of slices, see #typed?.
  #
  # A slice does not name the file, nor its streams, such as `.gz` or `.enc`: they were applied when the file was read,
  # so its rows are text in its format.
  #
  # To store a slice, or send it to another process, #to_h returns what it holds as a Hash, which `IOStreams.slice`
  # turns back into a slice.
  class Slice
    autoload :Collector, "io_streams/slice/collector"
    autoload :LineRows, "io_streams/slice/line_rows"
    autoload :Reader, "io_streams/slice/reader"
    autoload :Rows, "io_streams/slice/rows"
    autoload :Stream, "io_streams/slice/stream"
    autoload :Target, "io_streams/slice/target"
    autoload :TargetStream, "io_streams/slice/target_stream"
    autoload :Writer, "io_streams/slice/writer"

    # The keys of the Hash of a slice, see #to_h.
    KEYS = %w[rows header format blank_rows schema line_number record_number jumps].freeze

    # Returns [IOStreams::Slice] the slice that the supplied Hash describes, which #to_h returned, see `IOStreams.slice`.
    # Its keys can be Strings or Symbols, and its format a String or a Symbol, as storing it may have changed them. The
    # header row is a frozen copy, since every slice of a file shares it.
    #
    # Raises ArgumentError when it does not describe a slice: when it is not a Hash, has no rows, or a key that a slice
    # does not have, or when its rows are not an Array, its header row is not an Array of Strings, or is blank, see
    # #header?, its format is not a tabular format, see `IOStreams.tabular_formats`, its `blank_rows` is not true or false,
    # its `schema` is not a valid schema, see `IOStreams::Schema`, its `line_number` or `record_number` is not a
    # positive Integer, or is supplied without rows, or its `jumps` are not those of its rows, see #to_h. The values of
    # the rows of a slice with a schema are turned back into the types of their fields, see
    # `IOStreams::Schema::Field#load`.
    def self.from_h(hash)
      raise(ArgumentError, "A slice must be the Hash that #to_h returns, not #{hash.class.name}") unless hash.is_a?(::Hash)

      values  = hash.transform_keys(&:to_s)
      unknown = values.keys - KEYS
      unless unknown.empty?
        raise(ArgumentError, "Unknown #{unknown.size == 1 ? 'key' : 'keys'} #{unknown.map(&:inspect).join(', ')} of a " \
                             "slice. Valid keys: #{KEYS.map(&:inspect).join(', ')}")
      end

      slice = new(rows_of(values["rows"]), header: header_of(values["header"]), format: format_of(values["format"]),
                                           blank_rows: blank_rows_of(values["blank_rows"]),
                                           schema: values["schema"],
                                           line_number: values["line_number"], record_number: values["record_number"])
      slice.send(:jumps=, values["jumps"])
      slice.send(:load_rows)
      slice
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

    # Returns [Array<String>] the header row of the file, as it was read, before it was cleansed or matched to the
    # fields of a schema, which every slice of the file shares, so it is frozen, as are its columns.
    # Returns nil when the file has no header row, such as fixed width, JSON, or a schema whose `header` is false.
    attr_reader :header

    # Returns [true|false] whether the slice carries the header row of its file, see #header, which its rows are read by,
    # see `IOStreams::Slice::Stream`: false for the slices of a file without one, such as fixed width, JSON, or a schema
    # whose `header` is false, and for rows that are not of a file, such as an `:array` of values, so that none of its
    # rows is read as its header row, whatever the format or the schema that reads them says.
    def header?
      !@header.nil?
    end

    # Returns [Symbol] the tabular format of the rows, such as `:csv`, see `IOStreams.tabular_formats`.
    attr_reader :format

    # Returns [Integer] the line number of the first row, see #line_number_at, such as 2 for the first slice of a CSV
    # file whose header row is on line 1.
    # Returns nil when the first row has none, or the slice has no rows.
    attr_reader :line_number

    # Returns [Integer] the record number of the first row, see #record_number_at, such as 101 for the second slice of
    # 100 rows of a file.
    # Returns nil when the first row has none, or the slice has no rows.
    attr_reader :record_number

    # Parameters
    #   rows: [Array]
    #     The rows of the slice, which it holds a copy of, see #add.
    #     Default: none
    #
    #   header: [Array<String>]
    #     The header row of the file of the rows, see #header, which is not blank, since a blank row is never the header
    #     row of a file, or nil for rows without one, see #header?.
    #     Default: nil
    #
    #   format: [Symbol]
    #     The tabular format of the rows, see #format.
    #     Default: nil
    #
    #   blank_rows: [true|false]
    #     Whether a row whose every value is blank is a blank row, see #blank_rows?.
    #     Default: true
    #
    #   schema: [IOStreams::Schema|Hash|nil]
    #     The schema that the values of the rows are those of the fields of, see #schema, which only the rows of a format
    #     whose rows hold the values themselves, such as `:hash`, `:array` or `:parquet`, can have, see
    #     `IOStreams::Tabular.renders_values?`, since the rows of any other format are text.
    #     Default: nil
    #
    #   line_number: [Integer]
    #     The line of the file that the first row starts on, see #line_number_at. Each row after it is numbered as the
    #     next line.
    #     Default: nil, the rows are not lines of a file.
    #
    #   record_number: [Integer]
    #     The record number of the first row, see #record_number_at. Each row after it is numbered as the next record.
    #     Default: nil, the rows have no record numbers.
    #
    # A slice without rows has no numbers, since they are those of its first row: supply them when the row is added,
    # see #add.
    #
    # Raises ArgumentError when the rows are not an Array, for a header row that is not an Array, or is blank, for a
    # `schema` that is not a valid schema, or of a format whose rows are text, for a line number or record number that is
    # not a positive Integer, nor nil, or for one without rows, rather than ignore it.
    def initialize(rows = [], header: nil, format: nil, blank_rows: true, schema: nil, line_number: nil,
                   record_number: nil)
      raise(ArgumentError, "The rows of a slice must be an Array, not #{rows.class.name}") unless rows.is_a?(::Array)

      @rows          = rows.dup
      @header        = checked_header(header)
      @format        = format
      @blank_rows    = blank_rows
      @schema        = checked_schema(schema, format)
      @line_number   = checked_number("line_number", line_number)
      @record_number = checked_number("record_number", record_number)
      @jumps         = nil
      check_numbers_of_rows
      follow_last_row
    end

    # Returns [true|false] whether a row whose every value is blank, such as a line of CSV of only commas, is a blank
    # row, read as nil, as in a file, see `IOStreams::Tabular::Mapping`, which the tabular that read the rows decided,
    # see `IOStreams::Tabular#blank_rows?`. False when each row is a record, whatever its values, such as the rows of an
    # Active Record query, see `IOStreams::Query::Stream`, so that the stream of the slice reads a row whose every value
    # is null as a record too, see `IOStreams::Slice::Stream`.
    def blank_rows?
      @blank_rows
    end

    # Returns [IOStreams::Schema|nil] the schema that the values of the rows are those of the fields of, as their source
    # read them, such as the Integers, Dates and Durations of the rows of an Active Record query or a Parquet file, or of
    # the rows and records that a program wrote to a store of slices in the `:array` or `:hash` mode, see
    # `IOStreams::Slice::TargetStream`, so that a job reads them as their types without knowing them: the stream of the
    # slice reads them by it, see `IOStreams::Slice::Stream`, each value of the type of its field passing through, and
    # #to_h holds it, with each value in a form that JSON keeps, see `IOStreams::Schema::Field#dump`. Returns nil for the
    # rows of a file of text, such as CSV, which are parsed where they are read, as their file is.
    attr_reader :schema

    # Returns [true|false] whether the values of the rows are those of the fields of a schema, see #schema.
    def typed?
      !@schema.nil?
    end

    # Yields each row, as it is in the file, with its line number and record number, see #line_number_at and
    # #record_number_at:
    #
    #   slice.each do |row, line_number, record_number|
    #     puts "Record #{record_number}, on line #{line_number}: #{row}"
    #   end
    #
    # A block, lambda or method that takes one argument receives the row alone, such as `slice.each(&method(:process))`,
    # see #row_alone?.
    #
    # Returns self.
    # Returns an Enumerator of them without a block.
    def each(&block)
      return enum_for(:each) { size } unless block

      if row_alone?(block)
        @rows.each(&block)
        return self
      end

      line_number   = @line_number
      record_number = @record_number
      jumps         = @jumps
      next_jump     = 0
      jump_index    = jumps&.first&.first
      @rows.each_with_index do |row, index|
        if index == jump_index
          _, line_number, record_number = jumps[next_jump]
          next_jump += 1
          jump_index = jumps[next_jump]&.first
        end
        yield(row, line_number, record_number)
        line_number   += 1 if line_number
        record_number += 1 if record_number
      end
      self
    end

    # Returns [Array] the rows, as they are in the file, in an Array of their own, so that changing it does not change
    # the slice, such as to read them with the methods of an Array, see #each for their numbers.
    def rows
      @rows.dup
    end

    # Returns [Integer] the number of rows.
    def size
      @rows.size
    end

    # Returns [true|false] whether the slice has no rows.
    def empty?
      @rows.empty?
    end

    # Returns the row at the supplied index, counting from 0, or from the end for a negative index, as an Array does.
    # Returns nil when the slice has no row at the index.
    #
    # Raises ArgumentError for an index that is not an Integer.
    def [](index)
      @rows[check_index(index)]
    end

    # Returns [Integer] the line of the file that the row at the supplied index starts on, counting from 1, as a text
    # editor numbers it, so the header row and blank lines count, and a quoted value that holds line breaks counts each
    # of its lines, which puts the rows after it a line or more further down. For instance 2 for the first row of a CSV
    # file whose header row is on line 1.
    # Returns nil for a row that is not a line of a file, such as a row of Parquet, of an Active Record query, or a row
    # or record written to a store of slices in the `:array` or `:hash` mode, see `IOStreams::Slice::TargetStream`, or a
    # row added without one, see #add. A row of a spreadsheet, `.xlsx`, has none either, since its rows are read as CSV
    # text whose lines are not the rows of the sheet, see `IOStreams::Builder#lines_of_file?`.
    #
    # The index counts from 0, or from the end when it is negative, as for #[].
    #
    # Raises IndexError when the slice has no row at the index, and ArgumentError for an index that is not an Integer.
    def line_number_at(index)
      numbers_at(index).first
    end

    # Returns [Integer] the record number of the row at the supplied index: the number of the row in its file, counting
    # from 1, without the header row, nor the blank lines before it, so that a blank row after it counts. For instance
    # 101 for the first row of the second slice of 100 rows of a file. For the rows of a format whose rows are not
    # lines, such as Parquet, or of an Active Record query, it is the number of the row, as it is for the rows and
    # records written to a store of slices, see `IOStreams::Slice::TargetStream`. IOStreams counts it as it reads the
    # rows into slices, see `IOStreams::Slice::Collector`, while the slices read from a slice keep the record number of
    # each row, as they keep its line, see `IOStreams::Slice::Stream`.
    # Returns nil for a row added without one, see #add.
    #
    # The index counts from 0, or from the end when it is negative, as for #[].
    #
    # Raises IndexError when the slice has no row at the index, and ArgumentError for an index that is not an Integer.
    def record_number_at(index)
      numbers_at(index).last
    end

    # Adds the supplied row after the rows of the slice, with its line number and record number, see #line_number_at
    # and #record_number_at, such as a row of a file that is read in slices, see `IOStreams::Slice::Collector`.
    #
    #   slice.add("Jack,21", line_number: 2, record_number: 1)
    #
    # A row is added as the format of the slice holds it: a line of text, such as `"Jack,21"` for CSV, or for a format
    # whose rows are not lines, such as Parquet, the row that its reader returns.
    #
    # Parameters
    #   row: [String|Array|Hash|nil]
    #     The row to add.
    #
    #   line_number: [Integer]
    #     The line of the file that the row starts on.
    #     Default: nil, a row that is not a line of a file.
    #
    #   record_number: [Integer]
    #     The record number of the row.
    #     Default: nil, a row without one, such as a row that is not from a file.
    #
    # Returns self, so that calls can be chained.
    #
    # Raises ArgumentError for a line number or record number that is not a positive Integer, nor nil, and FrozenError
    # once the slice is frozen.
    def add(row, line_number: nil, record_number: nil)
      if @rows.empty?
        first          = [checked_number("line_number", line_number), checked_number("record_number", record_number)]
        @line_number   = first[0]
        @record_number = first[1]
      elsif !(@next_line_number.eql?(line_number) && @next_record_number.eql?(record_number))
        # A row that does not follow the row before it, whose numbers are checked here. Those of a row that follows it
        # are the Integers that the row before it gives the next row, or nil, since `eql?` is false for a Float or a
        # Rational of the same value.
        jump = [@rows.size, checked_number("line_number", line_number), checked_number("record_number", record_number)]
        (@jumps ||= []) << jump
      end
      @next_line_number   = line_number && (line_number + 1)
      @next_record_number = record_number && (record_number + 1)
      @rows << row
      self
    end

    # Adds the supplied row after the rows of the slice, without a line number or record number, see #add, such as a row
    # that is not from a file.
    #
    # Returns self, so that calls can be chained.
    def <<(row)
      add(row)
    end

    # Replaces the row at the supplied index, which keeps its numbers, see #each, such as to correct a row that could not
    # be processed, before it is processed again. The index counts from 0, or from the end when it is negative, as for
    # #[].
    #
    #   slice[3] = "Jack,21"
    #
    # Raises IndexError when the slice has no row at the index, ArgumentError for an index that is not an Integer, and
    # FrozenError once the slice is frozen.
    def []=(index, row)
      position = position_of(index)
      raise(IndexError, outside(index)) unless position

      check_frozen
      @rows[position] = row
    end

    # Removes the row at the supplied index. The rows after it keep their numbers, see #each. The index counts from 0,
    # or from the end when it is negative, as for #[].
    #
    # Returns the row removed.
    # Returns nil when the slice has no row at the index, as an Array does.
    #
    # Raises ArgumentError for an index that is not an Integer, and FrozenError once the slice is frozen.
    def delete_at(index)
      position = position_of(index)
      return unless position

      check_frozen
      numbered = numbered_rows
      removed  = numbered.delete_at(position)
      renumber(numbered)
      removed.first
    end

    # Removes each row for which the block returns true, which it yields with its numbers, as #each does. The rows that
    # are left keep their numbers.
    #
    #   slice.delete_if { |row, line_number, record_number| row.empty? }
    #
    # When the block raises, the slice is left as it was.
    #
    # Returns self.
    # Returns an Enumerator of the rows and their numbers without a block.
    #
    # Raises FrozenError once the slice is frozen.
    def delete_if(&block)
      return enum_for(:delete_if) { size } unless block

      check_frozen
      numbered = numbered_rows
      alone    = row_alone?(block)
      # Each row is yielded with its numbers as three values, as #each yields them, also to a lambda that takes them.
      numbered.delete_if { |numbers| alone ? block.call(numbers.first) : block.call(*numbers) }
      renumber(numbered)
      self
    end

    # Returns [IOStreams::Slice] a new slice of the rows after the first `count`, which keep their numbers, see #each,
    # with the header row and format of this slice, such as the rows that are still to be processed once the first
    # `count` were. This slice is left as it is, also when it is frozen.
    #
    #   slice.drop(40).each { |row, line_number, record_number| process(row) }
    #
    # Raises ArgumentError for a count that is not an Integer of zero or more.
    def drop(count)
      unless count.is_a?(::Integer) && !count.negative?
        raise(ArgumentError, "The number of rows to drop from a slice must be an Integer of 0 or more: #{count.inspect}")
      end

      rest = with_rows
      numbered_rows.drop(count).each do |row, line_number, record_number|
        rest.add(row, line_number: line_number, record_number: record_number)
      end
      rest
    end

    # Returns [IOStreams::Slice] a new slice of the supplied rows, without numbers, described as this slice is: with its
    # header row, its format, whether its blank rows are records, see #blank_rows?, and whether its values are those of
    # the fields of a schema, see #schema, such as when its rows are replaced by others in the same form, so that a
    # caller does not need to know what a slice holds to copy it. This slice is left as it is.
    #
    #   slice.with_rows(slice.rows.reject { |row| row.nil? })
    #
    # Raises ArgumentError when the rows are not an Array.
    def with_rows(rows = [])
      self.class.new(rows, header: header, format: format, blank_rows: blank_rows?, schema: schema)
    end

    # Returns [IOStreams::Slice] a new slice of the rows from the record of the supplied number on, which keep their
    # numbers, see #each, with the header row and format of this slice, such as the rows still to be processed by a job
    # that stopped before that record, see `IOStreams::Stream#each`'s `resume_at:`. This slice is left as it is, also
    # when it is frozen.
    #
    #   slice.from_record(502).each { |row, line_number, record_number| process(row) }
    #
    # It starts with the first row whose record number is the one supplied or later, so a record between its first and
    # last that the slice no longer holds, such as one removed with #delete_at, starts with the row after it. The record
    # after its last is the record after its rows, so it gives a slice without rows, such as for a job that stopped once
    # it had processed the last row, as does a slice without rows, which has none to skip.
    #
    # Raises ArgumentError for a record number that is not a positive Integer, or one before its first record or after
    # the record after its last, such as the position of a row within it, or the cursor of another slice, whose rows it
    # would skip. A slice holds only the numbers of its rows, so once its first or last rows are removed, it starts from
    # a record that it still holds. Also raises for a slice with a row without a record number, see #add, since it
    # cannot tell which records that row comes between.
    def from_record(record_number)
      unless record_number.is_a?(::Integer) && record_number.positive?
        raise(ArgumentError, "The record number to start a slice from must be a positive Integer: " \
                             "#{record_number.inspect}")
      end

      numbers = numbered_rows.map(&:last)
      return drop(0) if numbers.empty?
      if numbers.include?(nil)
        raise(ArgumentError, "A row of the slice has no record number, so it cannot start from record #{record_number}")
      end

      first, last = numbers.minmax
      unless record_number.between?(first, last + 1)
        raise(ArgumentError, "The slice holds records #{first} to #{last}, so it cannot start from record " \
                             "#{record_number}: supply one of them, or #{last + 1}, after its last")
      end

      drop(numbers.index { |number| number >= record_number } || numbers.size)
    end

    # Returns [Hash] what this slice holds, to store it or send it elsewhere, such as in the document of a job, which
    # `IOStreams.slice` turns back into a slice: its rows, the header row of its file, the format of its rows, and the
    # numbers of its rows, by String keys, with Strings, Integers, Arrays and nil, as JSON and BSON hold them, so that it
    # is the same once stored:
    # - `"line_number"` and `"record_number"`, those of its first row, when it has them, see #line_number and
    #   #record_number. Each row after it is numbered as the next line and the next record.
    # - `"jumps"`, only when a row does not follow the row before it, such as the row after a quoted value of CSV that
    #   holds a line break: the `[index, line_number, record_number]` of each such row, its index counting from 0, after
    #   which the rows are numbered from it.
    #
    # When each of its rows is a record, see #blank_rows?, it also holds `"blank_rows" => false`, which is otherwise left
    # out. A slice whose rows hold the values of the fields of a schema, see #schema, holds `"schema"`, the Frictionless
    # Table Schema, by String keys, about one row's worth of bytes, and each value of its rows in a form that JSON keeps
    # exactly, see `IOStreams::Schema::Field#dump`, such as a number as its digits, `"12.50"`, and a time in ISO 8601, so
    # that every job queue and store keeps them, and `IOStreams.slice` turns them back into their types.
    #
    # Example, of a slice whose second row holds a quoted value on lines 3 and 4, so that the third row starts on line 5:
    #   slice.to_h
    #   # => {"rows" => ["Jack,21", "Jill,\"line one\nline two\"", "Joe,23"], "header" => ["Name", "NOTE"],
    #   #     "format" => "csv", "line_number" => 2, "record_number" => 1, "jumps" => [[2, 5, 3]]}
    def to_h
      hash = {"rows" => stored_rows, "header" => header, "format" => format&.to_s}
      hash["blank_rows"]    = false unless blank_rows?
      hash["schema"]        = Utils.string_keys(schema.to_h) if schema
      hash["line_number"]   = line_number if line_number
      hash["record_number"] = record_number if record_number
      hash["jumps"]         = @jumps.map(&:dup) if @jumps
      hash
    end

    # Returns [Hash] what the slice holds, see #to_h, which ActiveSupport writes as JSON, applying the supplied options,
    # such as `only:` and `except:`, as it does to a Hash.
    #
    # Raises ArgumentError for options without ActiveSupport, which is what applies them, rather than ignore them.
    def as_json(options = nil)
      hash = to_h
      return hash.as_json(options) if hash.respond_to?(:as_json)
      return hash if options.nil? || options == {}

      raise(ArgumentError, "The options of Slice#as_json are applied by ActiveSupport, which is not loaded: " \
                           "#{options.inspect}")
    end

    # Returns [String] what the slice holds as JSON, see #to_h, which `IOStreams.slice(JSON.parse(json))` turns back
    # into the slice.
    def to_json(*)
      to_h.to_json(*)
    end

    # Returns [true|false] whether the rows of the supplied slice are read as those of this one, as rows of the same
    # file: of the same header row and format, and alike in whether their blank rows are records, see #blank_rows?, and
    # the schema that their values are those of the fields of, see #schema, such as the slices that a writer of slices
    # writes to one file, see `IOStreams::Slice::Writer`.
    def same_file?(other)
      other.is_a?(Slice) && other.description == description
    end

    # Slices are equal when they hold the same rows, with the same numbers, of the same header row and format, see #to_h.
    def ==(other)
      other.is_a?(Slice) && other.contents == contents
    end

    # Slices are the same hash key when what they hold is `eql?`, see #==, so that, as for an Array, rows that are only
    # equal by `==`, such as 1 and 1.0, are not.
    def eql?(other)
      other.is_a?(Slice) && other.contents.eql?(contents)
    end

    # Returns [Integer] the hash of what the slice holds, which slices that are `eql?` share, see #eql?.
    def hash
      contents.hash
    end

    # Freezes the slice, its rows and their numbers, so that a row cannot be added, see #add.
    def freeze
      @rows.freeze
      @jumps&.freeze
      super
    end

    # Returns [String] the class, the format, the numbers of the first row, and the rows.
    def inspect
      "#<#{self.class.name} format=#{format.inspect} line_number=#{line_number.inspect} " \
        "record_number=#{record_number.inspect} rows=#{@rows.inspect}>"
    end

    protected

    # Returns [Array] what the slice holds, as #to_h holds it, without copying its rows, which equal slices hold the same
    # of, see #==.
    def contents
      [@rows, header, format&.to_s, blank_rows?, schema, line_number, record_number, @jumps]
    end

    # Returns [Array] what describes how the rows of the slice are read, which the slices of the same file share, see
    # #same_file?.
    def description
      [header, format&.to_s, blank_rows?, schema]
    end

    private

    # A copy holds rows and numbers of its own, so that adding a row to it does not change the slice that it copies.
    def initialize_copy(other)
      super
      @rows  = @rows.dup
      @jumps = @jumps&.dup
    end

    # A frozen copy, such as the `#clone` of a frozen slice, also holds frozen rows and numbers, as #freeze does, since
    # Ruby freezes the copy without calling #freeze, so that a change, such as #add, raises FrozenError before it changes
    # anything.
    def initialize_clone(other, freeze: nil)
      super
      return unless freeze || (freeze.nil? && other.frozen?)

      @rows.freeze
      @jumps&.freeze
    end

    # Holds the supplied jumps, see #to_h, of the rows whose numbers do not follow those of the row before them, as
    # `.from_h` reads them, apart from those that do follow it, so that equal slices hold the same jumps, see #==.
    #
    # Raises ArgumentError for jumps that are not an Array of `[index, line_number, record_number]`, whose indexes are
    # those of the rows after the first, in order, and whose numbers are positive Integers or nil.
    def jumps=(jumps)
      unless jumps.nil? || jumps.is_a?(::Array)
        raise(ArgumentError, "The jumps of a slice must be an Array, not #{jumps.class.name}")
      end

      kept          = nil
      index         = 0
      line_number   = @line_number
      record_number = @record_number
      jumps&.each do |jump|
        jump   = checked_jump(jump, index)
        offset = jump.first - index
        unless jump[1] == (line_number && (line_number + offset)) && jump[2] == (record_number && (record_number + offset))
          (kept ||= []) << jump
        end
        index, line_number, record_number = jump
      end
      @jumps = kept
      follow_last_row
    end

    # Returns [Array(Integer, Integer, Integer)] a copy of the supplied jump, see #jumps=, of a row after the supplied
    # index.
    def checked_jump(jump, after)
      index, line_number, record_number = jump if jump.is_a?(::Array) && jump.size == 3
      unless index.is_a?(::Integer) && index > after && index < @rows.size
        raise(ArgumentError, "Each jump of a slice must be the [index, line_number, record_number] of one of its rows " \
                             "after the first, in order: #{jump.inspect}")
      end

      [index, checked_number("line_number", line_number), checked_number("record_number", record_number)]
    end

    # Returns [Array] the supplied header row, see #header, or nil for a slice without one, see #header?.
    #
    # Returns [IOStreams::Schema|nil] the supplied schema of a slice of the supplied format, see #schema, built from its
    # Hash, as #to_h holds it.
    #
    # Raises ArgumentError when it is not a valid schema, or is one of a format whose rows are text, such as CSV, since
    # its schema would then not read them, see `IOStreams::Tabular.renders_values?`.
    def checked_schema(schema, format)
      return if schema.nil?

      schema = IOStreams::Schema.new(schema) unless schema.is_a?(IOStreams::Schema)
      return schema if IOStreams::Tabular.renders_values?(format)

      raise(ArgumentError, "A slice of the #{format.inspect} format cannot have a schema, since its rows are text: only " \
                           "the rows of a format whose rows hold the values themselves, such as :hash or :array, can")
    end

    # Returns [Array] the rows as #to_h holds them: of a slice with a schema, each value in a form that JSON keeps, see
    # #dumped_rows, of a slice of values without one, such as the cells of a spreadsheet, each BigDecimal, Date and Time
    # as its text, see `IOStreams::Schema::Field.any_json`, which a contract reads back, and of a slice of lines, as
    # they are.
    def stored_rows
      return dumped_rows if schema
      return @rows.dup unless IOStreams::Tabular.renders_values?(format)

      @rows.map { |row| map_values(row, Hash.new(true)) { |_field, value| IOStreams::Schema::Field.any_json(value) } }
    end

    # Returns [Array] the rows of a slice with a schema, each value in a form that JSON keeps, see
    # `IOStreams::Schema::Field#dump`, for #to_h.
    def dumped_rows
      fields = row_fields
      @rows.map { |row| map_values(row, fields) { |field, value| field.dump(value) } }
    end

    # Turns the values of the rows of a slice with a schema back into the types of their fields, see
    # `IOStreams::Schema::Field#load`, from the forms that #to_h holds them in, see .from_h.
    #
    # Raises `IOStreams::Errors::InvalidValue` for a value that its field cannot hold, naming the record that it is in,
    # and the line that the record starts on.
    def load_rows
      return unless schema

      fields = row_fields
      @rows.each_index do |index|
        @rows[index] = map_values(@rows[index], fields) { |field, value| field.load(value) }
      rescue IOStreams::Errors::InvalidValue => e
        raise e.at(line_number: line_number_at(index), record_number: record_number_at(index))
      end
    end

    # Returns [Array|Hash] the values of the row, the value of each column whose field the fields name changed by the
    # block, the others as they are, by the position of each value of an Array, or the key of each value of a Hash, see
    # #row_fields.
    def map_values(row, fields)
      positions, keys = fields
      case row
      when ::Array
        row.each_with_index.map { |value, index| (field = positions[index]) && !value.nil? ? yield(field, value) : value }
      when ::Hash
        row.to_h { |key, value| [key, (field = keys[key]) && !value.nil? ? yield(field, value) : value] }
      else row
      end
    end

    # Returns [Array(Array, Hash)] the field of each column of the rows, by position, of the columns of the header row,
    # or for rows without one, every field of the schema in order, which their values are in, a field that only holds
    # the place of a column, `skip: true`, being nil; and by key, for a row that is a Hash, see #map_values.
    def row_fields
      keys      = Hash.new { |known, key| known[key] = field_of(key) }
      positions = header? ? header.map { |label| field_of(label) } : schema.fields.map { |field| field unless field.skip? }
      [positions, keys]
    end

    # Returns [IOStreams::Schema::Field|nil] the field of the schema of the column or key, or nil when it has none.
    def field_of(label)
      schema.field_for(label)
    rescue IOStreams::Errors::InvalidHeader
      nil
    end

    # Raises ArgumentError for a header row that is not an Array, such as false, or that is blank, see
    # `IOStreams::Utils.blank_row?`, such as `[]`, which reading would skip as a blank row, and take the first row as the
    # header row instead.
    def checked_header(header)
      return header if header.nil? || (header.is_a?(::Array) && !Utils.blank_row?(header))

      raise(ArgumentError, "The header row of a slice must be an Array of its columns that is not blank, or nil for a " \
                           "slice without one: #{header.inspect}")
    end

    # Returns [Integer] the supplied line number or record number of a row, or nil for a row without one.
    #
    # Raises ArgumentError for a number that is not a positive Integer, nor nil, naming it.
    def checked_number(name, number)
      return number if number.nil? || (number.is_a?(::Integer) && number.positive?)

      raise(ArgumentError, "The #{name} of a row of a slice must be a positive Integer, or nil: #{number.inspect}")
    end

    # Sets the numbers that a row added after the last row follows, see #add.
    def follow_last_row
      return if @rows.empty?

      line_number, record_number = numbers_at(-1)
      @next_line_number   = line_number && (line_number + 1)
      @next_record_number = record_number && (record_number + 1)
    end

    # Returns [Array(Integer, Integer)] the line number and record number of the row at the supplied index, see
    # #line_number_at and #record_number_at.
    def numbers_at(index)
      position = position_of(index)
      raise(IndexError, outside(index)) unless position

      line_number   = @line_number
      record_number = @record_number
      from          = 0
      if (jumps = @jumps)
        after = jumps.bsearch_index { |jump| jump.first > position } || jumps.size
        from, line_number, record_number = jumps[after - 1] if after.positive?
      end
      offset = position - from
      [line_number && (line_number + offset), record_number && (record_number + offset)]
    end

    # Returns [Integer] the position of the row at the supplied index, counting from 0, or from the end when the index is
    # negative, as for #[].
    # Returns nil when the slice has no row at the index.
    #
    # Raises ArgumentError for an index that is not an Integer.
    def position_of(index)
      position = check_index(index)
      position += @rows.size if position.negative?
      position if position >= 0 && position < @rows.size
    end

    # Returns [String] the message of the IndexError for the supplied index, outside of the rows.
    def outside(index)
      "index #{index} outside of the rows of the slice: #{-@rows.size}...#{@rows.size}"
    end

    # Returns [Array<Array>] each row with its numbers, `[row, line_number, record_number]`, see #each, in an Array of
    # their own, to change them, see #renumber.
    def numbered_rows
      numbered = []
      each { |row, line_number, record_number| numbered << [row, line_number, record_number] }
      numbered
    end

    # Holds the supplied rows with their numbers, `[row, line_number, record_number]`, see #numbered_rows, as the rows of
    # the slice, adding each one as #add does, so that its jumps are those of the rows, see #to_h.
    def renumber(numbered)
      @rows          = []
      @jumps         = nil
      @line_number   = nil
      @record_number = nil
      numbered.each { |row, line_number, record_number| add(row, line_number: line_number, record_number: record_number) }
    end

    # Returns [true|false] whether to yield the supplied block the row alone, rather than with its numbers, see #each:
    # when it takes one argument, such as `{ |row| }`, or a lambda or a method of one, which Ruby would otherwise raise
    # for, since it takes exactly the values yielded to it.
    def row_alone?(block)
      block.arity == 1
    end

    # Raises ArgumentError for numbers of the first row of a slice without rows, see #initialize.
    def check_numbers_of_rows
      return unless @rows.empty? && !(@line_number.nil? && @record_number.nil?)

      raise(ArgumentError, "A slice without rows has no line_number or record_number, since they are those of its " \
                           "first row: supply them when it is added, with #add(row, line_number:, record_number:)")
    end

    # Raises FrozenError once the slice is frozen, before it is changed.
    def check_frozen
      raise(FrozenError.new("can't modify frozen #{self.class.name}: #{inspect}", receiver: self)) if frozen?
    end

    # Returns [Integer] the supplied index of a row.
    #
    # Raises ArgumentError for an index that is not an Integer.
    def check_index(index)
      return index if index.is_a?(::Integer)

      raise(ArgumentError, "The index of a row of a slice must be an Integer, not #{index.class.name}")
    end
  end
end
