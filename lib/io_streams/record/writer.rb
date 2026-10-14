# frozen_string_literal: true

module IOStreams
  module Record
    # Example, implied header from first record:
    #   IOStreams.path('file.csv').writer(:hash) do |stream|
    #     stream << {name: 'Jack', address: 'Somewhere', zipcode: 12345}
    #     stream << {name: 'Joe', address: 'Lost', zipcode: 32443, age: 23}
    #   end
    class Writer < IOStreams::Writer
      # Returns [Array<Symbol>] the options that this writer accepts, see .stream: its own, and those of the
      # `IOStreams::Tabular` that writes the records, other than the file name, which it supplies.
      def self.option_names
        [:original_file_name, *(IOStreams::Tabular.write_option_names - %i[file_name])]
      end

      # Write a record as a Hash at a time to a stream.
      # Note:
      # - The supplied stream _must_ already be a line stream, or a stream that responds to :<<
      #
      # Parameters
      #   original_file_name: [String]
      #     When `:format` is not supplied the file name can be used to infer the required format.
      #     Optional. Default: nil
      #
      #   format: [Symbol]
      #     :csv, :hash, :array, :json, :psv, :fixed or :parquet, see `IOStreams::Tabular.new`.
      #
      #   schema: [IOStreams::Schema]
      #     The fields of the file and the type of each one, see `IOStreams::Tabular.new`. The `:fixed` format needs it
      #     for the position of each field. With a schema, `columns` raises ArgumentError, since the schema describes the
      #     columns of the file.
      #
      #   format_options: [Hash]
      #     Deprecated, use `schema:`, see `IOStreams::Tabular.new`.
      #
      #   columns [Array<String|Symbol>]
      #     Deprecated: the fields of a schema are the columns, see `schema:`.
      #     The header columns when the file does not include a header row.
      #     Note:
      #       Column names are converted to strings.
      #
      # The options that restrict the columns read, `allowed_columns`, `required_columns` and `skip_unknown`, only apply
      # when reading, so they are not options of this writer, see .option_names, and `IOStreams::Stream#writer` raises
      # ArgumentError for them.
      def self.stream(line_writer, original_file_name: nil, **args)
        # Pass-through if already a record writer
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

      # Create a writer that takes individual records as hashes.
      #
      # Parameters
      #   line_writer: [#<<]
      #     Anything that accepts a line / record at a time when #<< is called on it.
      #
      #   tabular: [IOStreams::Tabular]
      #     Renders each record in its format, and holds the header.
      def initialize(line_writer, tabular:)
        raise(ArgumentError, "Stream must be a IOStreams::Line::Writer or implement #<<") unless line_writer.respond_to?(:<<)

        @tabular     = tabular
        @line_writer = line_writer

        # The header line of the columns supplied, or of the fields of a schema, see `IOStreams::Tabular#start_records`.
        @tabular.start_records { |line| @line_writer << line }
      end

      # Writes the record, after the header line that the keys of the first record give, when neither the columns
      # supplied nor a schema give it, see `IOStreams::Tabular#render_record`.
      #
      # Returns self, so that calls can be chained.
      def <<(hash)
        raise(ArgumentError, "#<< only accepts a Hash argument") unless hash.is_a?(Hash)

        @tabular.render_record(hash) { |line| @line_writer << line }
        self
      end
    end
  end
end
