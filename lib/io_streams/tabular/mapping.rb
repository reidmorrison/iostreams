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
    # * `IOStreams::Tabular::LayoutMapping`: by the layout of a fixed width file, which is deprecated, whose schema reads
    #   and renders the values, while the column options still apply to its records.
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
      def initialize(header:, parser:, format:)
        @header = header
        @parser = parser
        @format = format
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
      # JSON record of `null`, `{}`, or whose every value is null.
      def parse(line)
        return if IOStreams::Utils.blank?(line)

        values = @parser.parse(line)
        values unless IOStreams::Utils.blank_row?(values)
      end
    end
  end
end
