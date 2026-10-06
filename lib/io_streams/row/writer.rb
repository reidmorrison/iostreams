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
      #
      # Parameters
      #   original_file_name: [String]
      #     The file name from which to infer the format, see `IOStreams::Tabular.new`.
      #
      #   For all other parameters, see `IOStreams::Tabular.new`.
      def self.stream(line_writer, original_file_name: nil, **args)
        # Pass-through if already a row writer
        return yield(line_writer) if line_writer.is_a?(self.class)

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
        line_writer << @tabular.render_header if @tabular.requires_header? && !@tabular.header?
      end

      # Supply a hash or an array to render
      #
      # Returns self, so that calls can be chained.
      def <<(array)
        raise(ArgumentError, "Must supply an Array") unless array.is_a?(Array)

        # If header (columns) was not supplied as an argument, assume first line is the header.
        @line_writer << (@tabular.header? ? @tabular.render_header(array) : @tabular.render(array))
        self
      end
    end
  end
end
