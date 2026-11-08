# frozen_string_literal: true

module IOStreams
  module Row
    # Converts each line of an input stream into an array for every line, for `IOStreams::Stream#each(:array)` and
    # `#reader(:array)`, which create it with the tabular of the stream.
    class Reader
      include Enumerable
      include IOStreams::Row::Numbered

      # Returns [Array<Symbol>] the options of each call that reads rows, see `IOStreams::Stream#reader`, which raises
      # for any other: those of the lines that it reads, see .line_option_names, whether to skip the blank rows, and the
      # record that reading resumes at, see #initialize. The tabular that parses them takes the settings of the path
      # instead, such as its schema.
      def self.option_names
        [*line_option_names, :skip_blanks, :resume_at, :on_invalid]
      end

      # Returns [Array<Symbol>] the options of the lines that rows are read from, which a call supplies: those of
      # `IOStreams::Line::Reader.option_names`, other than `embedded_within`, since the format of the file splits the
      # lines of its rows where its parser expects, see `IOStreams::Tabular#quote_character`. Also those of records and
      # slices, which are read from rows.
      def self.line_option_names
        IOStreams::Line::Reader.option_names - %i[embedded_within]
      end

      # Raises ArgumentError for a `skip_blanks` that is not true or false, or a `resume_at` that is neither nil nor a
      # positive Integer, see #initialize, so that a call raises before the file is opened, see `IOStreams::Stream#each`.
      def self.check(skip_blanks: false, resume_at: nil, on_invalid: nil)
        IOStreams::Utils.check_boolean(:skip_blanks, skip_blanks)
        IOStreams::Utils.check_record_number(:resume_at, resume_at)
        IOStreams::Row::Numbered.check_on_invalid(on_invalid)
      end

      # Create a reader that returns the stream rows as arrays.
      #
      # Parameters
      #   line_reader: [#each]
      #     Anything that returns one line / record at a time when #each is called on it.
      #
      #   tabular: [IOStreams::Tabular]
      #     Parses each line in its format, and holds the header, see `IOStreams::Tabular#read_row`.
      #
      #   skip_blanks: [true|false]
      #     Whether #each skips each blank row, rather than yield nil for it: a line that is empty or only whitespace, or
      #     a row whose every value is nil or blank text, such as a line of CSV of only commas, see
      #     `IOStreams::Tabular#blank?`. Keep the default to count the lines of the file from the rows yielded, such as to
      #     report the line of a row that is not valid.
      #     Default: false
      #
      #   resume_at: [Integer|nil]
      #     The number of the record that reading resumes at, so that #each yields the rows from that record on, such as
      #     to resume the work of a job that processed the records before it. Records are counted as the slices of the
      #     file number them, see `IOStreams::Slice#record_number_at`: from 1, without the header row, nor the blank
      #     lines before it, so that a blank row after it counts. The lines of the records before it are read, but not
      #     parsed. #each still yields the header row first, see #header?.
      #     Default: nil, every row
      #
      #   on_invalid: [#call|nil]
      #     Called with an `IOStreams::InvalidRow` for each row whose values are not all valid for their fields, rather
      #     than raise `IOStreams::Errors::InvalidValue` for the first, so that reading carries on, see
      #     `IOStreams::Record::Reader#initialize`.
      #     Default: nil
      def initialize(line_reader, tabular:, skip_blanks: false, resume_at: nil, on_invalid: nil)
        self.class.check(skip_blanks: skip_blanks, resume_at: resume_at, on_invalid: on_invalid)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular     = tabular
        @line_reader = line_reader
        @skip_blanks = skip_blanks
        @on_invalid  = on_invalid
        # The number of records before `resume_at`, which #each reads without parsing.
        @skip        = resume_at ? resume_at - 1 : 0
      end

      # Returns [true|false] whether nothing names the columns of the rows, see `IOStreams::Tabular#unnamed_columns?`, such
      # as the rows of the :text format without a schema, so that a copy checks that its target can write them, see
      # `IOStreams::Stream#check_unnamed_rows`. Asked before #each.
      def unnamed_columns?
        @tabular.unnamed_columns?
      end

      # Returns [true|false] whether the first row that #each yields is a header row, which names the column of each
      # value of the rows after it, so that a copy can write it as a header row, see `IOStreams::Row::Writer#write_header`:
      # the header row of the file, the names of the fields of a schema of a file without one, such as fixed width, or
      # the keys of the first record of a format of keyed records, such as JSON, without a schema, see
      # `IOStreams::Tabular#rows_header?`. Asked before #each.
      def header?
        @tabular.rows_header?
      end

      # Yields the header row, an `IOStreams::Row::HeaderRow`, followed by each row, an Array, whatever the format, see
      # #header?. A file without a header row,
      # such as fixed width, or JSON with a schema, yields the names of the fields of the schema as the header row, and
      # each row is the values of the fields, in order. The header row of JSON without a schema is the keys of its first
      # record, and each row the values of a record in that order, see `IOStreams::Tabular#read_row`.
      #
      # Without a schema, the header row is yielded as it was read, before it is cleansed, and each row contains every
      # value.
      #
      # With a schema, the header row is the names of the fields of its columns, and each row is the values of those
      # fields, in the order of the fields, without the columns that the schema skips, see `IOStreams::Tabular#row_parse`.
      #
      # A blank row is yielded as nil, unless `skip_blanks` is true, which skips it, see #initialize. With `resume_at`,
      # the rows start with that record, without parsing the records before it: a line is a record once the tabular no
      # longer expects the header row, see `IOStreams::Tabular#header?`, and the tabular yields the header row that the
      # rows of a file start with when it is not a line of its own from the first record skipped, see
      # `IOStreams::Tabular#skip_record`, such as the keys of the first record of JSON without a schema. A value that is
      # not valid raises `IOStreams::Errors::InvalidValue`, naming its record and line, unless `on_invalid:` takes the
      # row, see `IOStreams::Row::Numbered#invalid`. Any other error of a row that cannot be read, such as a line of CSV
      # whose quoting is not valid, names them too, see `IOStreams::Errors::RowError`, and an error of the header row its
      # line.
      #
      # Returns an Enumerator of the rows without a block.
      def each(&)
        return enum_for(:each) unless block_given?

        read_rows(false, &)
      end

      # Yields each row as #each does, with the line of the file that it starts on and its record number, so that a
      # program can say where in the file a row is, such as for a row that it cannot process:
      # - The line that the row starts on, counting from 1, the header row and blank lines included, as a text editor
      #   numbers them, or nil for a row that is not a line of a file, such as a row of Parquet or of a query, see
      #   `IOStreams::Slice#line_number_at`.
      # - The record number of the row, counting from 1 without the header row, as the slices of the file and an
      #   `IOStreams::Errors::RowError` number them, see `IOStreams::Slice#record_number_at`, or nil for the header row,
      #   which is not a record.
      # The rows of a slice have the numbers that the slice holds, see `IOStreams::Slice::Stream`, nil for a row that a
      # slice of numbered rows holds without them, while the rows of a slice that holds no record numbers are counted, and
      # its header row, whose line it does not hold, has no line number either. A blank line
      # before the header row, which is yielded as nil, has its line, and no record number.
      #
      # The header row of the file has its line, while a header row that is not a line of its own has none, such as the
      # keys of the first record of JSON without a schema, or the names of the fields of a file without a header row, see
      # #header?. `skip_blanks`, `resume_at` and `on_invalid` apply as they do to #each, and every row keeps the numbers of
      # its file.
      #
      # Returns an Enumerator of the rows and their numbers without a block.
      def each_with_numbers(&)
        return enum_for(:each_with_numbers) unless block_given?

        read_rows(true, &)
      end

      # Writes each row to the writer, see `IOStreams::Row::Writer`, as a copy does, see `IOStreams::Stream#copy_from`,
      # telling it the column of each value of the rows: it writes the header row of the file, an
      # `IOStreams::Row::HeaderRow`, which the writer takes as their header row, see `IOStreams::Row::Writer#<<`, so that
      # a format without one, such as JSON, takes their columns from it, rather than write it as a row of values, or, for
      # a file without a header row, whose header row #each yields from the names of the fields of its schema, those
      # columns, see `IOStreams::Tabular#headerless_columns`, before the first line is read. A blank line, which #each
      # yields as nil, is not a row, so it is not written.
      #
      # Returns the result of #each.
      def copy_to(writer)
        columns = @tabular.headerless_columns
        writer.write_header(columns) if columns
        each do |row|
          # The header row of a file without one is the columns, which were written above.
          next if row.nil? || (columns && row.is_a?(HeaderRow))

          writer << row
        end
      end

      # Returns [IOStreams::Schema|nil] the schema that the source of the lines declares, such as that of a Parquet file,
      # see `IOStreams::Parquet::Reader#declared_schema`, which a copy gives a typed target, see
      # `IOStreams::Stream#rows_schema`, or nil for lines of text.
      def declared_schema
        @line_reader.declared_schema if @line_reader.respond_to?(:declared_schema)
      end

      # Returns [String] the class and the format of the rows, see `IOStreams::Tabular#format`, rather than every instance
      # variable, such as the tabular and the lines that it reads, so that irb, which displays what a reader block
      # returns, shows what the documentation describes.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect}>"
      end

      private

      # Reads the rows for #each and #each_with_numbers, yielding each row alone, or with its line number and record
      # number when `numbered` is true, so that both share one loop, which yields to the block of the caller without a
      # block of its own for each row.
      def read_rows(numbered, &)
        skip    = @skip
        records = 0
        # Whether the source gives the record number of each row, such as a slice, see #records_numbered?, otherwise
        # the records are counted.
        source_numbers = records_numbered?
        # Yields a header row, or the first row, that the methods of the reader read once for a file, see #read_header,
        # #skip_record and #read_first, which yield each one with its numbers, as the caller asks. Each other row is
        # yielded below, without a block of its own. A lambda, so that #each yields the row alone, which a Proc that
        # yields its arguments would not, since it would hand the numbers on too.
        once    = numbered ? ->(row, *numbers) { yield(row, *numbers) } : ->(row, *) { yield(row) }
        # Whether the rows that the tabular yields have started, after the header row, once it is read, or the header
        # row that the rows of a file without one start with, such as the keys of the first record of JSON without a
        # schema, see `IOStreams::Tabular#rows_header?`, after which every line is one row.
        started = false
        each_numbered do |line, line_number, record_number|
          if !started && @tabular.header?
            read_header(line, line_number, &once)
            next
          end

          records += 1
          number = source_numbers ? record_number : records
          if skip.positive?
            skip -= 1
            skip_record(line, line_number, number, &once)
          elsif started || !@tabular.rows_header?
            started = true
            # Rescued here, rather than in `IOStreams::Row::Locator.locate`, whose block would cost each row more.
            begin
              row = @tabular.row_parse(line)
            rescue IOStreams::Errors::InvalidValue => e
              next invalid(e, line, line_number, number)
            rescue IOStreams::Errors::RowError => e
              raise e.at(line_number: line_number, record_number: number)
            end
            next if @skip_blanks && row.nil?

            numbered ? yield(row, line_number, number) : yield(row)
          else
            read_first(line, line_number, number, &once)
          end
        end
      end

      # Yields the header row of the supplied line, see `IOStreams::Tabular#read_row`, with the line number and no record
      # number, unless it is blank and `skip_blanks` skips it, once it is read, outside the rescue that names the line of an
      # `IOStreams::Errors::RowError` that reading it raises, since the header row is not a record.
      def read_header(line, line_number)
        yielded = false
        header  = nil
        IOStreams::Row::Locator.locate(line_number: line_number) do
          @tabular.read_row(line) do |row|
            yielded = true
            header  = row
          end
        end
        yield(header, line_number, nil) if yielded && !(@skip_blanks && header.nil?)
      end

      # Yields the header row that the rows of a file start with when it is not a line of its own from the supplied
      # line of a record that `resume_at` skips, see `IOStreams::Tabular#skip_record`, such as the keys of the first
      # record of JSON without a schema, without numbers, since it is not a line of its own, once it is read, outside the
      # rescue that names the record and line of an `IOStreams::Errors::RowError` that reading it raises.
      def skip_record(line, line_number, record_number)
        columns = nil
        IOStreams::Row::Locator.locate(line_number: line_number, record_number: record_number) do
          @tabular.skip_record(line) { |header| columns = header }
        end
        yield(columns, nil, nil) if columns
      end

      # Yields the header row that the rows of a file start with when it is not a line of its own, such as the keys of
      # the first record of JSON without a schema, or the names of the fields of a file without a header row, from the
      # supplied line of its first record, see `IOStreams::Tabular#read_row`, without numbers, then the row of that
      # record, with its line number and record number, unless it is blank and `skip_blanks` skips it, or its values are
      # not all valid and `on_invalid:` takes it, see `IOStreams::Row::Numbered#invalid`.
      def read_first(line, line_number, record_number)
        header = nil
        row    = nil
        begin
          IOStreams::Row::Locator.locate(line_number: line_number, record_number: record_number) do
            @tabular.read_row(line) { |parsed| parsed.is_a?(HeaderRow) ? header = parsed : row = [parsed] }
          end
        rescue IOStreams::Errors::InvalidValue => e
          yield(header, nil, nil) if header
          return invalid(e, line, line_number, record_number)
        end
        yield(header, nil, nil) if header
        yield(row.first, line_number, record_number) if row && !(@skip_blanks && row.first.nil?)
      end
    end
  end
end
