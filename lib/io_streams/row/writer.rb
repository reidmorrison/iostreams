require "csv"
module IOStreams
  module Row
    # Example:
    #   IOStreams.path("file.csv").writer(:array) do |stream|
    #     stream << ['name', 'address', 'zipcode']
    #     stream << ['Jack', 'Somewhere', 12345]
    #     stream << ['Joe', 'Lost', 32443]
    #   end
    class Writer < IOStreams::Writer
      # Write a record from an Array at a time to a stream.
      #
      # Note:
      # - The supplied stream _must_ already be a line stream, or a stream that responds to :<<
      def self.stream(line_writer, **args)
        # Pass-through if already a row writer
        return yield(line_writer) if line_writer.is_a?(self.class)

        yield new(line_writer, **args)
      end

      # When writing to a file also add the line writer stream
      def self.file(file_name, original_file_name: file_name, delimiter: $/, **args, &block)
        IOStreams::Line::Writer.file(file_name, delimiter: delimiter) do |io|
          yield new(io, original_file_name: original_file_name, **args, &block)
        end
      end

      # Create a Tabular writer that takes individual rows as arrays.
      #
      # Parameters
      #   line_writer: [#<<]
      #     Anything that accepts a line / record at a time when #<< is called on it.
      #
      #   format: [Symbol]
      #     :csv, :hash, :array, :json, :psv, :fixed
      #
      #   tabular: [IOStreams::Tabular]
      #     The tabular that renders each row, such as one with a schema, see `IOStreams::Stream#schema`, in place of the
      #     other options, which create it.
      #
      #   For all other parameters, see Tabular::Header.new
      def initialize(line_writer, columns: nil, original_file_name: nil, tabular: nil, **args)
        raise(ArgumentError, "Stream must be a IOStreams::Line::Writer or implement #<<") unless line_writer.respond_to?(:<<)

        if tabular && (columns || original_file_name || !args.empty?)
          raise(ArgumentError, "Supply either tabular: or the options that create it, not both")
        end

        IOStreams::Tabular.check_write_options(args)
        @tabular     = tabular || IOStreams::Tabular.new(columns: columns, file_name: original_file_name, **args)
        @line_writer = line_writer

        # Render header line when `columns` is supplied, or with a schema the names of its fields, see
        # `IOStreams::Tabular#start_rows`.
        @tabular.start_rows { |line| @line_writer << line }
      end

      # Supply an array to render, otherwise it raises ArgumentError.
      #
      # Without a schema, the first row is the header row, unless the columns were supplied. With a schema, the header
      # row of a file with one is the names of its fields, which is written before the rows, so every row written is
      # the values of the fields, in order. A header row that `IOStreams::Stream#each(:array)` yields with a schema, an
      # `IOStreams::Row::HeaderRow`, is written as the header row of the rows after it, see #write_header.
      def <<(array)
        raise(ArgumentError, "Must supply an Array") unless array.is_a?(Array)
        return write_header(array) if array.is_a?(HeaderRow)

        @tabular.render_row(array) { |line| @line_writer << line }
      end

      # Writes the header row of the rows after it, such as that of the file that is copied, see
      # `IOStreams::Row::Reader#copy_to`, so that the value of each column of the rows after it is written to its
      # column, or to its field with a schema, whose columns it matches to the fields, without a line. Without a schema,
      # as the first row, see #<<, unless the format has no header row, such as JSON, and the columns are not known,
      # when it gives the columns of the rows after it, or the columns were supplied, which name them instead, see
      # `IOStreams::Tabular#render_header_row`.
      #
      # Returns self, so that calls can be chained.
      def write_header(columns)
        @tabular.render_header_row(columns) { |line| @line_writer << line }
        self
      end
    end
  end
end
