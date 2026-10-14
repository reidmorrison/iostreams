# frozen_string_literal: true

require "csv"
module IOStreams
  module Row
    # Example:
    #   IOStreams.path("file.csv").writer(:array) do |stream|
    #     stream << ['name', 'address', 'zipcode']
    #     stream << ['Jack', 'Somewhere', 12345]
    #     stream << ['Joe', 'Lost', 32443]
    #   end
    #
    # The first row is the header row, as `each(:array)` returns it, unless the columns are supplied. With a schema, the
    # header row of the file is the names of its fields, and the first row is still the header row of the rows after
    # it, whose columns are matched to the fields, so that a row is written in the order of the fields, and the rows
    # read from another file can be written as they are, see `IOStreams::Schema::Columns#match_written`. Unless the file
    # has no header row, such as JSON or a schema with `header: false`, whose rows are the values of the fields, in
    # order.
    class Writer < IOStreams::Writer
      # Returns [Array<Symbol>] the options that this writer accepts, see .stream: its own, and those of the
      # `IOStreams::Tabular` that writes the rows, other than the file name, which it supplies.
      def self.option_names
        [:original_file_name, *(IOStreams::Tabular.write_option_names - %i[file_name])]
      end

      # Write a record from an Array at a time to a stream.
      #
      # Note:
      # - The supplied stream _must_ already be a line stream, or a stream that responds to :<<
      #
      # Parameters
      #   original_file_name: [String]
      #     The file name from which to infer the format, see `IOStreams::Tabular.new`.
      #
      #   For all other parameters, see `IOStreams::Tabular.new`.
      def self.stream(line_writer, original_file_name: nil, **args)
        # Pass-through if already a row writer
        return yield(line_writer) if line_writer.is_a?(self)

        yield new(line_writer, tabular: IOStreams::Tabular.new(file_name: original_file_name, **args))
      end

      # When writing to a file also add the line writer stream. See `.stream` for the parameters.
      def self.file(file_name, original_file_name: file_name, delimiter: $/, **args)
        tabular = IOStreams::Tabular.new(file_name: original_file_name, **args)
        IOStreams::Line::Writer.file(file_name, delimiter: delimiter) do |io|
          yield new(io, tabular: tabular)
        end
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

        # Render the header line when the columns were supplied.
        line_writer << @tabular.render_header if @tabular.requires_header? && !@tabular.first_row_header?
      end

      # Writes the header row of rows read from a file with one, see `IOStreams::Row::Reader#header?`, so that the value
      # of each column of the rows after it is written to its column, or to its field with a schema: as the columns of
      # the rows after it, for a format without a header row, such as JSON or Parquet, otherwise as the first row, see
      # #<<, including when the columns were supplied, see `IOStreams::Tabular#columns_from_header_row?`.
      #
      # Returns self, so that calls can be chained.
      def write_header(columns)
        return self << columns unless @tabular.columns_from_header_row?

        @tabular.render_header(columns)
        self
      end

      # Takes the columns of the rows written after it, which are not a row of the file that they are read from, such as
      # the fields of a file without a header row, see `IOStreams::Row::Reader#copy_to`: like its header row, see
      # #write_header, they name the column, or with a schema the field, of each value of the rows, unless the columns
      # were supplied, which name them instead, so that they are not written as a row of values.
      #
      # Returns self, so that calls can be chained.
      def write_columns(columns)
        @tabular.columns_supplied? ? self : write_header(columns)
      end

      # Supply a hash or an array to render
      #
      # Returns self, so that calls can be chained.
      def <<(array)
        raise(ArgumentError, "Must supply an Array") unless array.is_a?(Array)

        # If header (columns) was not supplied as an argument, assume first line is the header.
        @line_writer << (@tabular.first_row_header? ? @tabular.render_header(array) : @tabular.render(array))
        self
      end
    end
  end
end
