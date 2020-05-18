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

        yield new(line_writer, file_name: original_file_name, **args)
      end

      # When writing to a file also add the line writer stream
      def self.file(file_name, original_file_name: file_name, delimiter: $/, **args, &block)
        IOStreams::Line::Writer.file(file_name, original_file_name: original_file_name, delimiter: delimiter) do |io|
          yield new(io, file_name: original_file_name, **args, &block)
        end
      end

      # Create a Tabular writer that takes individual
      # Parse a delimited data source.
      #
      # Parameters
      #   format: [Symbol]
      #     :csv, :hash, :array, :json, :psv, :fixed
      #
      #   file_name: [String]
      #     When `:format` is not supplied the file name can be used to infer the required format.
      #     Optional. Default: nil
      #
      #   format_options: [Hash]
      #     Any specialized format specific options. For example, `:fixed` format requires the file definition.
      #
      #   columns [Array<String>]
      #     The header columns when the file does not include a header row.
      #     Note:
      #       It is recommended to keep all columns as strings to avoid any issues when persistence
      #       with MongoDB when it converts symbol keys to strings.
      #
      #   allowed_columns [Array<String>]
      #     List of columns to allow.
      #     Default: nil ( Allow all columns )
      #     Note:
      #       When supplied any columns that are rejected will be returned in the cleansed columns
      #       as nil so that they can be ignored during processing.
      #
      #   required_columns [Array<String>]
      #     List of columns that must be present, otherwise an Exception is raised.
      #
      #   skip_unknown [true|false]
      #     true:
      #       Skip columns not present in the `allowed_columns` by cleansing them to nil.
      #       #as_hash will skip these additional columns entirely as if they were not in the file at all.
      #     false:
      #       Raises Tabular::InvalidHeader when a column is supplied that is not in the whitelist.
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
