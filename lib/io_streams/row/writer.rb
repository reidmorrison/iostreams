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
        IOStreams::Line::Writer.file(file_name, original_file_name: original_file_name, delimiter: delimiter) do |io|
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
      #   For all other parameters, see Tabular::Header.new
      def initialize(line_writer, columns: nil, original_file_name: nil, **args)
        raise(ArgumentError, "Stream must be a IOStreams::Line::Writer or implement #<<") unless line_writer.respond_to?(:<<)

        @tabular     = IOStreams::Tabular.new(columns: columns, file_name: original_file_name, **args)
        @line_writer = line_writer

        # Render header line when `columns` is supplied.
        line_writer << @tabular.render_header if columns && @tabular.requires_header?
      end

      # Supply a hash or an array to render
      def <<(array)
        raise(ArgumentError, "Must supply an Array") unless array.is_a?(Array)

        if @tabular.header?
          # If header (columns) was not supplied as an argument, assume first line is the header.
          @tabular.header.columns = array
          @line_writer << @tabular.render_header
        else
          @line_writer << @tabular.render(array)
        end
      end
    end
  end
end
