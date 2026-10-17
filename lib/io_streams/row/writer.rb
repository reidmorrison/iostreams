# frozen_string_literal: true

module IOStreams
  module Row
    # Example:
    #   IOStreams.path("file.csv").writer(:array) do |stream|
    #     stream << ['name', 'address', 'zipcode']
    #     stream << ['Jack', 'Somewhere', 12345]
    #     stream << ['Joe', 'Lost', 32443]
    #   end
    #
    # Without a schema, the first row is the header row, as `each(:array)` returns it, unless the columns are supplied.
    # The first row written to JSON is the header row too, which names the key of each value of the rows after it,
    # without a line of its own. A header row after the first row, even an `IOStreams::Row::HeaderRow`, is written as a
    # row of values, since without a schema its columns cannot be matched to those of the file.
    #
    # With a schema, the header row of a file with one is the names of its fields, which the writer writes before the
    # rows, so every row written is the values of the fields, in order, as for a file without a header row:
    #
    #   IOStreams.path("file.csv").schema(fields: [{name: "name"}, {name: "zip", type: "integer"}]).writer(:array) do |io|
    #     io << ["Jack", 12345]
    #   end
    #   # => "name,zip\nJack,12345\n"
    #
    # A header row written to it, such as the `IOStreams::Row::HeaderRow` that `each(:array)` yields, gives the columns
    # of the rows after it instead, which are matched to the fields, so that the rows read from another file can be
    # written as they are, see #write_header and `IOStreams::Schema::Columns#match_written`.
    #
    # `IOStreams::Stream#writer(:array)` creates it with the tabular of the stream.
    class Writer
      # Returns [Array<Symbol>] the options of each call that writes rows, see `IOStreams::Stream#writer`, which raises
      # for any other: those of the lines that it writes, see `IOStreams::Line::Writer.option_names`, and those of the
      # `IOStreams::Tabular` that renders them, see `IOStreams::Tabular.write_option_names`.
      def self.option_names
        [*IOStreams::Line::Writer.option_names, *IOStreams::Tabular.write_option_names]
      end

      # Returns [Array<Symbol>] the options of .option_names that are deprecated, which a call still accepts: those of the
      # lines that it writes, see `IOStreams::Line::Writer.deprecated_option_names`, and of the tabular that renders them,
      # see `IOStreams::Tabular.deprecated_option_names`.
      def self.deprecated_option_names
        [*IOStreams::Line::Writer.deprecated_option_names, *IOStreams::Tabular.deprecated_option_names] & option_names
      end

      # Create a writer that takes individual rows as arrays.
      #
      # Parameters
      #   line_writer: [#<<]
      #     Anything that accepts a line / record at a time when #<< is called on it.
      #
      #   tabular: [IOStreams::Tabular]
      #     Renders each row in its format, and holds the header.
      def initialize(line_writer, tabular:)
        raise(ArgumentError, "Stream must be a IOStreams::Line::Writer or implement #<<") unless line_writer.respond_to?(:<<)

        @tabular     = tabular
        @line_writer = line_writer

        # The header line of the columns supplied, see `IOStreams::Tabular#start_rows`.
        @tabular.start_rows { |line| @line_writer << line }
      end

      # Writes the header row of rows read from a file with one, see `IOStreams::Row::Reader#header?`, so that the value
      # of each column of the rows after it is written to its column, or to its field with a schema: as the columns of
      # the rows after it, for a format without a header row, such as JSON or Parquet, otherwise as the first row, see
      # `IOStreams::Tabular#render_header_row`.
      #
      # Returns self, so that calls can be chained.
      def write_header(columns)
        @tabular.render_header_row(columns) { |line| @line_writer << line }
        self
      end

      # Takes the columns of the rows written after it, which are not a row of the file that they are read from, such as
      # the fields of a file without a header row, see `IOStreams::Row::Reader#copy_to`: like its header row, see
      # #write_header, they name the column, or with a schema the field, of each value of the rows, unless the columns
      # were supplied, which name them instead, see `IOStreams::Tabular#render_columns`.
      #
      # Returns self, so that calls can be chained.
      def write_columns(columns)
        @tabular.render_columns(columns) { |line| @line_writer << line }
        self
      end

      # Supply a hash or an array to render. Without a schema, the first row is the header row, unless the columns were
      # supplied, see `IOStreams::Tabular#render_row`, and with one, every row is the values of the fields, in order, see
      # above. A header row that `IOStreams::Stream#each(:array)` yields, an `IOStreams::Row::HeaderRow`, is written as
      # the header row of the rows after it, see #write_header: with a schema, whichever row it is, otherwise as the first
      # row, as any first row is, so that the rows read from one file can be written to another as they are, whatever
      # their formats.
      #
      # Returns self, so that calls can be chained.
      def <<(array)
        raise(ArgumentError, "Must supply an Array") unless array.is_a?(Array)
        return write_header(array) if array.is_a?(HeaderRow)

        @tabular.render_row(array) { |line| @line_writer << line }
        self
      end

      # Returns [String] the class and the format of the rows, see `IOStreams::Tabular#format`, rather than every instance
      # variable, such as the tabular and the lines that it writes, so that irb, which displays what a writer block
      # returns, such as the writer that `io << row` returns, shows what the documentation describes.
      def inspect
        "#<#{self.class.name} format=#{@tabular.format.inspect}>"
      end
    end
  end
end
