module IOStreams
  module Record
    # Converts each line of an input stream into hash for every row
    class Reader < IOStreams::Reader
      include Enumerable

      # Read a record at a time from a line stream
      # Note:
      # - The supplied stream _must_ already be a line stream, or a stream that responds to :each
      #
      # Parameters
      #   original_file_name: [String]
      #     When `:format` is not supplied the file name can be used to infer the required format.
      #     Optional. Default: nil
      #
      #   cleanse_header: [true|false]
      #     See #initialize.
      #
      #   format: [Symbol]
      #     :csv, :hash, :array, :json, :psv, :fixed
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
      # Note:
      # * `allowed_columns`, `required_columns` and `skip_unknown` apply to every input, including JSON records,
      #   supplied `columns` and `cleanse_header: false`, unless `IOStreams.enforce_column_restrictions?` is false.
      def self.stream(line_reader, original_file_name: nil, cleanse_header: true, **args)
        # Pass-through if already a record reader
        return yield(line_reader) if line_reader.is_a?(self.class)

        tabular = IOStreams::Tabular.new(file_name: original_file_name, **args)
        yield new(line_reader, tabular: tabular, cleanse_header: cleanse_header)
      end

      # When reading from a file also add the line reader stream, which splits the lines where the format expects,
      # such as within a quoted CSV value. See `.stream` for the parameters.
      def self.file(file_name, original_file_name: file_name, delimiter: $/, cleanse_header: true, **args)
        tabular = IOStreams::Tabular.new(file_name: original_file_name, **args)
        IOStreams::Line::Reader.file(file_name, delimiter: delimiter, embedded_within: tabular.quote_character) do |io|
          yield new(io, tabular: tabular, cleanse_header: cleanse_header)
        end
      end

      # Create a reader to return the stream as Hash records.
      #
      # Parameters
      #   line_reader: [#each]
      #     Anything that returns one line / record at a time when #each is called on it.
      #
      #   tabular: [IOStreams::Tabular]
      #     Parses each line in its format, and holds the header.
      #
      #   cleanse_header: [true|false]
      #     Whether to cleanse the header row, see `IOStreams::Tabular::Header#cleanse!`.
      #     Default: true
      def initialize(line_reader, tabular:, cleanse_header: true)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular        = tabular
        @line_reader    = line_reader
        @cleanse_header = cleanse_header

        # Supplied columns take the place of a header row, so apply the allowed and required columns to them.
        @tabular.restrict_columns(rename: cleanse_header)
      end

      def each
        @line_reader.each do |line|
          if @tabular.header?
            @tabular.read_header(line, cleanse: @cleanse_header)
          else
            yield @tabular.read_record(line, rename: @cleanse_header)
          end
        end
      end
    end
  end
end
