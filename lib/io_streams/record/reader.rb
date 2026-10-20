module IOStreams
  module Record
    # Converts each line of an input stream into hash for every row
    class Reader < IOStreams::Reader
      include Enumerable

      # Read a record at a time from a line stream
      # Note:
      # - The supplied stream _must_ already be a line stream, or a stream that responds to :each
      def self.stream(line_reader, **args)
        # Pass-through if already a record reader
        return yield(line_reader) if line_reader.is_a?(self.class)

        yield new(line_reader, **args)
      end

      # When reading from a file also add the line reader stream
      def self.file(file_name, original_file_name: file_name, delimiter: $/, **args)
        IOStreams::Line::Reader.file(file_name, delimiter: delimiter) do |io|
          yield new(io, original_file_name: original_file_name, **args)
        end
      end

      # Create a Tabular reader to return the stream as Hash records
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
      #   columns [Array<String|Symbol>]
      #     The header columns when the file does not include a header row.
      #     Note:
      #       Column names are converted to strings.
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
      #
      #   cleanse_header: [true|false]
      #     Whether to cleanse the header row read, see `IOStreams::Tabular::Header#cleanse!`.
      #     Default: `IOStreams::Tabular::CLEANSE_BY_DEFAULT`, which cleanses it.
      #
      # Note:
      # * `allowed_columns`, `required_columns` and `skip_unknown` only apply to every input, including JSON records,
      #   supplied `columns` and `cleanse_header: false`, when `IOStreams.enforce_column_restrictions?` is true.
      def initialize(line_reader, cleanse_header: IOStreams::Tabular::CLEANSE_BY_DEFAULT, original_file_name: nil, **args)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular        = IOStreams::Tabular.new(file_name: original_file_name, **args)
        @line_reader    = line_reader
        @cleanse_header = cleanse_header

        # Supplied columns take the place of a header row, so apply the allowed and required columns to them.
        @tabular.restrict_columns(cleanse: @cleanse_header)
      end

      # Yields each record, after the header row, which names their keys, see `IOStreams::Tabular#read_record_line`.
      def each(&block)
        @line_reader.each { |line| @tabular.read_record_line(line, cleanse: @cleanse_header, &block) }
      end
    end
  end
end
