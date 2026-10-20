# frozen_string_literal: true

module IOStreams
  class Tabular
    # Maps the columns of one file to the values of its rows and records, for `IOStreams::Tabular`, which asks it to
    # read and render them rather than depend on what describes the columns. The Tabular chooses one when it is created:
    #
    # * `IOStreams::Tabular::HeaderMapping`: by the columns of the header row, or the columns supplied in place of one,
    #   and the column options, held by its header, see `IOStreams::Tabular::Header`.
    #
    # Each one does the same things, in its own way:
    # * Reads the lines of a file: its header row, `#parse_header` and `#read_header`, and its rows and records,
    #   `#row_parse` and `#record_parse`, which its parser parses.
    # * Renders the rows and records written into lines, `#render`, and the header row, `#render_header`.
    # * Reads and writes a line at a time for the readers and writers of rows and records, see `IOStreams::Row::Reader`
    #   and the others, which only iterate: `#read_row`, `#read_record_line` and `#restrict_columns` when reading,
    #   `#start_rows`, `#render_row`, `#start_records` and `#render_record` when writing.
    # * Answers the questions of the protocol: whether the file has a header row, `#requires_header?`, and whether it is
    #   still to be read, `#header?`.
    #
    # The reading methods take the `cleanse_header` option of the reader that reads the lines, as `cleanse:`, since the
    # reader holds it, see `IOStreams::Row::Reader#initialize`.
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
    end
  end
end
