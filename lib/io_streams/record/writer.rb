module IOStreams
  module Record
    # Example, implied header from first record:
    #   IOStreams.path('file.csv').writer(:hash) do |stream|
    #     stream << {name: 'Jack', address: 'Somewhere', zipcode: 12345}
    #     stream << {name: 'Joe', address: 'Lost', zipcode: 32443, age: 23}
    #   end
    class Writer < IOStreams::Writer
      # Write a record as a Hash at a time to a stream.
      # Note:
      # - The supplied stream _must_ already be a line stream, or a stream that responds to :<<
      def self.stream(line_writer, original_file_name: nil, **args)
        # Pass-through if already a record writer
        return yield(line_writer) if line_writer.is_a?(self.class)

        yield new(line_writer, **args)
      end

      # When writing to a file also add the line writer stream
      def self.file(file_name, original_file_name: file_name, delimiter: $/, **args, &block)
        IOStreams::Line::Writer.file(file_name, original_file_name: original_file_name, delimiter: delimiter) do |io|
          yield new(io, **args, &block)
        end
      end

      # Create a Tabular writer that takes individual
      # Parse a delimited data source.
      #
      # Parameters
      #   delimited: [#<<]
      #     Anything that accepts a line / record at a time when #<< is called on it.
      #
      #   format: [Symbol]
      #     :csv, :hash, :array, :json, :psv, :fixed
      #
      #   For all other parameters, see Tabular::Header.new
      def initialize(line_writer, columns: nil, **args)
        raise(ArgumentError, "Stream must be a IOStreams::Line::Writer or implement #<<") unless line_writer.respond_to?(:<<)

        @tabular     = IOStreams::Tabular.new(columns: columns, **args)
        @line_writer = line_writer

        # Render header line when `columns` is supplied.
        @line_writer << @tabular.render_header if columns && @tabular.requires_header?
      end

      def <<(hash)
        raise(ArgumentError, "#<< only accepts a Hash argument") unless hash.is_a?(Hash)

        if @tabular.header?
          # Extract header from the keys from the first row when not supplied above.
          @tabular.header.columns = hash.keys
          @line_writer << @tabular.render_header
        end
        @line_writer << @tabular.render(hash)
      end
    end
  end
end
