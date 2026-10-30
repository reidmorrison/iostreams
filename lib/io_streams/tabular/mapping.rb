# frozen_string_literal: true

module IOStreams
  class Tabular
    # Maps the columns of one file to the values of its rows and records, for `IOStreams::Tabular`, which asks it to
    # read and render them rather than depend on what describes the columns. The Tabular chooses one when it is created:
    #
    # * `IOStreams::Tabular::HeaderMapping`, without a schema: by the columns of the header row, or the columns
    #   supplied in place of one, and the column options, held by its header, see `IOStreams::Tabular::Header`.
    # * `IOStreams::Tabular::SchemaMapping`, with a schema: by its fields, see `IOStreams::Schema::Columns`.
    #
    # Each one does the same things, in its own way, by the methods below, which each one implements:
    # * Reads the lines of a file: its header row, `#parse_header` and `#read_header`, and its rows and records,
    #   `#row_parse` and `#record_parse`, which its parser parses.
    # * Renders the rows and records written into lines, `#render`, and the header row, `#render_header`.
    # * Reads and writes a line at a time for the readers and writers of rows and records, see `IOStreams::Row::Reader`
    #   and the others, which only iterate: `#read_row`, `#read_record_line` and `#restrict_columns` when reading,
    #   `#start_copy` and `#copy_row` when the rows read are copied, `#start_rows`, `#render_row`, `#start_records` and
    #   `#render_record` when writing, and `#render_header_row` for the header row of the rows written, such as that of
    #   the file that is copied.
    # * Cleanses the header row, `#cleanse_header!`, when the keys of the records are the columns of the file.
    # * Answers the questions of the protocol: whether the file has a header row, `#requires_header?`, whether it is
    #   still to be read, `#header?`, whether the rows read start with a header row, `#rows_header?`, whether they are
    #   records rather than Arrays, `#record_rows?`, and the columns of the rows of a file without one,
    #   `#headerless_columns`.
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

      # Returns [true|false] whether the header row is still to be read, see `IOStreams::Tabular#header?`.
      def header?
        raise NotImplementedError
      end

      # Returns [true|false] whether the file has a header row, see `IOStreams::Tabular#requires_header?`.
      def requires_header?
        raise NotImplementedError
      end

      # Returns [true|false] whether the rows read start with a header row, see `IOStreams::Tabular#rows_header?`.
      def rows_header?
        raise NotImplementedError
      end

      # Returns [true|false] whether the rows read are the records of the file, see `IOStreams::Tabular#record_rows?`.
      def record_rows?
        raise NotImplementedError
      end

      # Returns [Array<String|Symbol>|nil] the columns of the rows of a file without a header row, see
      # `IOStreams::Tabular#headerless_columns`.
      def headerless_columns
        raise NotImplementedError
      end

      # Returns [Array|nil] the header row parsed from the line, see `IOStreams::Tabular#parse_header`.
      def parse_header(line)
        raise NotImplementedError
      end

      # Returns [Array|nil] the header row read from the line, see `IOStreams::Tabular#read_header`.
      def read_header(line, cleanse: nil)
        raise NotImplementedError
      end

      # Returns [Array|nil] the row of the line, see `IOStreams::Tabular#row_parse`.
      def row_parse(line)
        raise NotImplementedError
      end

      # Returns [Hash|nil] the record of the line, see `IOStreams::Tabular#record_parse`.
      def record_parse(line)
        raise NotImplementedError
      end

      # Returns [String|Array|Hash|nil] the line of the row or record written, see `IOStreams::Tabular#render`.
      def render(row)
        raise NotImplementedError
      end

      # Returns [String|nil] the header row written, see `IOStreams::Tabular#render_header`.
      def render_header
        raise NotImplementedError
      end

      # Yields each row of the line of a file of rows, see `IOStreams::Tabular#read_row`.
      def read_row(line)
        raise NotImplementedError
      end

      # Yields the record of the line of a file of records, see `IOStreams::Tabular#read_record_line`.
      def read_record_line(line)
        raise NotImplementedError
      end

      # Applies the column restrictions to the columns supplied, see `IOStreams::Tabular#restrict_columns`.
      def restrict_columns
        raise NotImplementedError
      end

      # Returns [Array<String>] the header columns once they are cleansed, see `IOStreams::Tabular#cleanse_header!`.
      def cleanse_header!
        raise NotImplementedError
      end

      # Yields the header row that a copy writes before the first line, see `IOStreams::Tabular#start_copy`.
      def start_copy
        raise NotImplementedError
      end

      # Yields each row of the line that a copy writes, see `IOStreams::Tabular#copy_row`.
      def copy_row(line)
        raise NotImplementedError
      end

      # Yields the header line written before the first row, see `IOStreams::Tabular#start_rows`.
      def start_rows
        raise NotImplementedError
      end

      # Yields the line written for the row, see `IOStreams::Tabular#render_row`.
      def render_row(row)
        raise NotImplementedError
      end

      # Yields the line written for the header row of the rows after it, see `IOStreams::Tabular#render_header_row`.
      def render_header_row(columns)
        raise NotImplementedError
      end

      # Yields the header line written before the first record, see `IOStreams::Tabular#start_records`.
      def start_records
        raise NotImplementedError
      end

      # Yields each line written for the record, see `IOStreams::Tabular#render_record`.
      def render_record(record)
        raise NotImplementedError
      end
    end
  end
end
