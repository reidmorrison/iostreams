# frozen_string_literal: true

module IOStreams
  module Row
    # Converts each line of an input stream into an array for every line, for `IOStreams::Stream#each(:array)` and
    # `#reader(:array)`, which create it with the tabular of the stream.
    class Reader
      include Enumerable

      # Returns [Array<Symbol>] the options of each call that reads rows, see `IOStreams::Stream#reader`, which raises
      # for any other: those of the lines that it reads, see .line_option_names, whether to skip the blank rows, see
      # #initialize, and those of the `IOStreams::Tabular` that parses them, see `IOStreams::Tabular.read_option_names`.
      def self.option_names
        [*line_option_names, :skip_blanks, *IOStreams::Tabular.read_option_names]
      end

      # Returns [Array<Symbol>] the options of the lines that rows are read from, which a call supplies: those of
      # `IOStreams::Line::Reader.option_names`, other than `embedded_within`, since the format of the file splits the
      # lines of its rows where its parser expects, see `IOStreams::Tabular#quote_character`. Also those of records and
      # slices, which are read from rows.
      def self.line_option_names
        IOStreams::Line::Reader.option_names - %i[embedded_within]
      end

      # Raises ArgumentError for a `skip_blanks` that is not true or false, see #initialize, so that a call raises before
      # the file is opened, see `IOStreams::Stream#each`.
      def self.check(skip_blanks: false)
        IOStreams::Utils.check_boolean(:skip_blanks, skip_blanks)
      end

      # Returns [Array<Symbol>] the options of .option_names that are deprecated, which a call still accepts: those of the
      # lines, see `IOStreams::Line::Reader.deprecated_option_names`, and those of the tabular, see
      # `IOStreams::Tabular.deprecated_option_names`.
      def self.deprecated_option_names
        [*IOStreams::Line::Reader.deprecated_option_names, *IOStreams::Tabular.deprecated_option_names]
      end

      # Create a reader that returns the stream rows as arrays.
      #
      # Parameters
      #   line_reader: [#each]
      #     Anything that returns one line / record at a time when #each is called on it.
      #
      #   tabular: [IOStreams::Tabular]
      #     Parses each line in its format, holds the header, and cleanses the header row as its `cleanse_header`
      #     option says, see `IOStreams::Tabular.new`.
      #
      #   skip_blanks: [true|false]
      #     Whether #each skips each blank row, rather than yield nil for it: a line that is empty or only whitespace, or
      #     a row whose every value is nil or blank text, such as a line of CSV of only commas, see
      #     `IOStreams::Tabular#blank?`. Keep the default to count the lines of the file from the rows yielded, such as to
      #     report the line of a row that is not valid.
      #     Default: false
      def initialize(line_reader, tabular:, skip_blanks: false)
        self.class.check(skip_blanks: skip_blanks)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular     = tabular
        @line_reader = line_reader
        @skip_blanks = skip_blanks

        # Supplied columns take the place of a header row, so apply the allowed and required columns to them.
        @tabular.restrict_columns
      end

      # Returns [true|false] whether the first row that #each yields is a header row, which names the column of each
      # value of the rows after it, so that a copy can write it as a header row, see `IOStreams::Row::Writer#write_header`:
      # the header row of the file, the names of the fields of a schema of a file without one, such as fixed width, or
      # the keys of the first record of a format of keyed records, such as JSON, without a schema, see
      # `IOStreams::Tabular#rows_header?`. False when the columns were supplied, which name the values of the rows
      # instead. Asked before #each.
      def header?
        @tabular.rows_header?
      end

      # Yields the header row, an `IOStreams::Row::HeaderRow`, followed by each row, an Array, whatever the format, unless
      # the columns were supplied, which name the values of the rows instead, see #header?. A file without a header row,
      # such as fixed width, or JSON with a schema, yields the names of the fields of the schema as the header row, and
      # each row is the values of the fields, in order. The header row of JSON without a schema is the keys of its first
      # record, and each row the values of a record in that order, see `IOStreams::Tabular#read_row`.
      #
      # The allowed and required columns are applied to the header row, or to the supplied columns,
      # even when `cleanse_header` is false, unless `IOStreams.enforce_column_restrictions?` is false.
      # Each row still contains every value.
      #
      # With a schema, the header row is the names of the fields of its columns, and each row is the values of those
      # fields, in the order of the fields, without the columns that the schema skips, see `IOStreams::Tabular#row_parse`.
      #
      # A blank row is yielded as nil, unless `skip_blanks` is true, which skips it, see #initialize.
      def each(&block)
        return @line_reader.each { |line| @tabular.read_row(line, &block) } unless @skip_blanks

        @line_reader.each { |line| @tabular.read_row(line) { |row| yield row unless row.nil? } }
      end

      # Writes each row to the writer, see `IOStreams::Row::Writer`, as a copy does, see `IOStreams::Stream#copy_from`,
      # telling it the column of each value of the rows: it writes the header row of the file, an
      # `IOStreams::Row::HeaderRow`, which the writer takes as their header row, see `IOStreams::Row::Writer#<<`, so that
      # a format without one, such as JSON, takes their columns from it, rather than write it as a row of values, or, for
      # a file without a header row, whose header row #each yields from the names of the fields of its schema, those
      # columns instead, see `IOStreams::Row::Writer#write_columns`, which the columns supplied to the writer name
      # instead. The header row of a file with a schema names its fields, see
      # `IOStreams::Tabular#field_names?`, so it is written as their columns too, which the columns supplied to the writer
      # name instead, while the header row of a file without one is written as before, as the first row. A blank line,
      # which #each yields as nil, is not a row, so it is not written.
      #
      # Returns the result of #each.
      def copy_to(writer)
        columns = @tabular.headerless_columns
        writer.write_columns(columns) if columns
        fields  = @tabular.field_names?
        each do |row|
          # The header row of a file without one is the columns, which were written above.
          next if row.nil? || (columns && row.is_a?(HeaderRow))

          fields && row.is_a?(HeaderRow) ? writer.write_columns(row) : writer << row
        end
      end

      # Returns [String] the class and the format of the rows, see `IOStreams::Tabular#format`, rather than every instance
      # variable, such as the tabular and the lines that it reads, so that irb, which displays what a reader block
      # returns, shows what the documentation describes.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect}>"
      end
    end
  end
end
