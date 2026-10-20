# frozen_string_literal: true

module IOStreams
  class Tabular
    # Maps the columns of one file to the values of its rows and records, for `IOStreams::Tabular`, which asks it to
    # read and render them rather than depend on what describes the columns. The Tabular chooses one when it is created:
    #
    # * `IOStreams::Tabular::HeaderMapping`, without a schema: by the columns of the header row, or the columns
    #   supplied in place of one, and the column options, which are deprecated, held by its header, see
    #   `IOStreams::Tabular::Header`.
    # * `IOStreams::Tabular::SchemaMapping`: by the fields of a schema, see `IOStreams::Schema::Columns`.
    #
    # Each one does the same things, in its own way:
    # * Reads the lines of a file: its header row, `#parse_header` and `#read_header`, and its rows and records,
    #   `#row_parse`, `#record_parse` and `#read_record`, which its parser parses, applying the column options, see
    #   `#restrict_columns`.
    # * Renders the rows and records written into lines, `#render`, and the header row, `#render_header`: it arranges
    #   each one in the form of the rows of the format, which its parser renders, see
    #   `IOStreams::Tabular::Parser::Base.keyed?`: a record by the names of the columns for a format of keyed records,
    #   such as JSON, otherwise the values in the order of the columns, such as for CSV.
    # * Answers the questions of the header-row protocol of the readers and writers, see `IOStreams::Tabular#read_row`
    #   and the others: whether the file has a header row, `#requires_header?`, whether it is still to be read,
    #   `#header?`, whether the rows read start with a header row, `#rows_header?`, which `#read_rows_header` reads when
    #   it is not a line of its own, such as the keys of the first record of JSON without a schema, or the names of the
    #   fields of a file without a header row, whether the next row written is the header row, `#first_row_header?`, and
    #   where the columns of the rows written come from, `#columns_from_first_row?`, `#columns_from_header_row?`, which
    #   `#take_columns` takes, and `#columns_supplied?`.
    # * Answers whether the keys of the records read are the names of fields, `#field_names?`, and the columns of the
    #   rows of a file without a header row, `#headerless_columns`.
    # * Cleanses the columns of the header row, `#cleanse_header!`, without a schema, whose fields name the keys of the
    #   records read instead.
    # * Checks the keys of the first record of a file whose rows are handed on without being parsed, `#check_keys`, see
    #   `IOStreams::Tabular#read_line`.
    #
    # Each row is an Array, whatever the format: the values of the columns of the rows, in order, which a parser of
    # keyed records, such as JSON, gives by their keys. A row already read, an Array, is read as such, see
    # `IOStreams::Tabular#record_parse`.
    #
    # Each reader and writer has its own, through its Tabular, since it holds the columns of one file.
    class Mapping
      # Returns [IOStreams::Tabular::Header] the columns of the file: the header row read, or the columns supplied in
      # place of one, and the column options, see `IOStreams::Tabular#header`.
      attr_reader :header

      # Parameters:
      #   header: [IOStreams::Tabular::Header]
      #     The columns of the file, and the column options of the call that reads or writes it.
      #
      #   parser: [IOStreams::Tabular::Parser::Base]
      #     Parses and renders each line of the file in its format.
      #
      #   format: [Symbol]
      #     The name of the format, for the messages of errors.
      #
      #   blank_rows: [true|false]
      #     Whether a row whose every value is blank is a blank row, read as nil, see #parse, as in a file. False for rows
      #     that are each a record, whatever their values, such as the rows of a database query, see
      #     `IOStreams::Query::Stream`.
      #     Default: true
      def initialize(header:, parser:, format:, blank_rows: true)
        @header     = header
        @parser     = parser
        @format     = format
        @blank_rows = blank_rows
      end

      # The methods of the role, which each mapping implements in its own way, see above, and which
      # `IOStreams::Tabular` asks it, so that a mapping that leaves one out raises NotImplementedError, rather than
      # NoMethodError. Each is described where `IOStreams::Tabular` calls it, such as `IOStreams::Tabular#row_parse`.
      def requires_header?
        raise(NotImplementedError, "#{self.class.name} does not implement #requires_header?")
      end

      def header?
        raise(NotImplementedError, "#{self.class.name} does not implement #header?")
      end

      def rows_header?
        raise(NotImplementedError, "#{self.class.name} does not implement #rows_header?")
      end

      def field_names?
        raise(NotImplementedError, "#{self.class.name} does not implement #field_names?")
      end

      def headerless_columns
        raise(NotImplementedError, "#{self.class.name} does not implement #headerless_columns")
      end

      def columns_supplied?
        raise(NotImplementedError, "#{self.class.name} does not implement #columns_supplied?")
      end

      def columns_from_first_row?
        raise(NotImplementedError, "#{self.class.name} does not implement #columns_from_first_row?")
      end

      def first_row_header?
        raise(NotImplementedError, "#{self.class.name} does not implement #first_row_header?")
      end

      def columns_from_header_row?
        raise(NotImplementedError, "#{self.class.name} does not implement #columns_from_header_row?")
      end

      def take_columns(_columns)
        raise(NotImplementedError, "#{self.class.name} does not implement #take_columns")
      end

      def parse_header(_line)
        raise(NotImplementedError, "#{self.class.name} does not implement #parse_header")
      end

      def read_header(_line, **)
        raise(NotImplementedError, "#{self.class.name} does not implement #read_header")
      end

      def read_rows_header(_line)
        raise(NotImplementedError, "#{self.class.name} does not implement #read_rows_header")
      end

      def restrict_columns(**)
        raise(NotImplementedError, "#{self.class.name} does not implement #restrict_columns")
      end

      def row_parse(_line)
        raise(NotImplementedError, "#{self.class.name} does not implement #row_parse")
      end

      def record_parse(_line)
        raise(NotImplementedError, "#{self.class.name} does not implement #record_parse")
      end

      def read_record(_line)
        raise(NotImplementedError, "#{self.class.name} does not implement #read_record")
      end

      def render(_row)
        raise(NotImplementedError, "#{self.class.name} does not implement #render")
      end

      def render_header(_columns = nil)
        raise(NotImplementedError, "#{self.class.name} does not implement #render_header")
      end

      def cleanse_header!
        raise(NotImplementedError, "#{self.class.name} does not implement #cleanse_header!")
      end

      # Checks the keys of the first record of a file whose rows are handed on without being parsed, see
      # `IOStreams::Tabular#read_line`: nothing, since without a schema the keys of each record are its columns. A
      # schema matches them to its fields, see `IOStreams::Tabular::SchemaMapping#check_keys`.
      def check_keys(_line)
        nil
      end

      private

      # Returns [Array|Hash] the values of the line, which the parser parses, or a row already read, as it is.
      #
      # Returns nil when it is blank, the same way in every format, so that a file holds the same rows whichever format it
      # is in: a line that is blank, see `IOStreams::Utils.blank_text?`, or a row or record whose every value is blank,
      # see `IOStreams::Utils.blank_row?`, such as a line of CSV of only commas, a spreadsheet row of empty cells, or a
      # JSON record of `null`, `{}`, or whose every value is null, unless blank rows are records, see #initialize.
      def parse(line)
        return if IOStreams::Utils.blank?(line)

        values = @parser.parse(line)
        values unless @blank_rows && IOStreams::Utils.blank_row?(values)
      end
    end
  end
end
