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
      # Note:
      # * `allowed_columns`, `required_columns` and `skip_unknown` only apply to every input, including JSON records,
      #   supplied `columns` and `cleanse_header: false`, when `IOStreams.enforce_column_restrictions?` is true.
      def initialize(line_reader, cleanse_header: true, original_file_name: nil, **args)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular        = IOStreams::Tabular.new(file_name: original_file_name, **args)
        @line_reader    = line_reader
        @cleanse_header = cleanse_header
        @warned         = false

        # Supplied columns take the place of a header row, so apply the allowed and required columns to them.
        restrict_columns if restricted? && !@tabular.header?
      end

      def each
        @line_reader.each do |line|
          if @tabular.header?
            @tabular.parse_header(line)
            if @cleanse_header
              cleanse_columns
            elsif restricted?
              restrict_columns
            end
          else
            yield restrict(@tabular.record_parse(line))
          end
        end
      end

      private

      def restricted?
        @tabular.header.restricted?
      end

      def cleanse_columns
        @tabular.header.cleanse!(rename: @cleanse_header)
      end

      # Apply the allowed and required columns to supplied columns, or to a header row read with
      # `cleanse_header: false`. Unless `IOStreams.enforce_column_restrictions?`, only warn when they would
      # change the columns.
      def restrict_columns
        return cleanse_columns if IOStreams.enforce_column_restrictions?
        return if @warned

        header  = @tabular.header
        columns = header.columns
        changed = changed_by_restriction? do
          copy = IOStreams::Tabular::Header.new(
            columns:          columns,
            allowed_columns:  header.allowed_columns,
            required_columns: header.required_columns,
            skip_unknown:     header.skip_unknown
          )
          copy.cleanse!(rename: @cleanse_header)
          copy.columns != columns
        end
        warn_restriction if changed
      end

      # Formats such as JSON have no header row, so apply the allowed and required columns to each record's keys.
      # Unless `IOStreams.enforce_column_restrictions?`, only warn when they would change the record.
      def restrict(record)
        return record unless record.is_a?(Hash) && restricted? && @tabular.header.columns.nil?
        return @tabular.header.restrict_hash(record, rename: @cleanse_header) if IOStreams.enforce_column_restrictions?
        return record if @warned

        warn_restriction if changed_by_restriction? { @tabular.header.restrict_hash(record, rename: @cleanse_header) != record }
        record
      end

      def changed_by_restriction?
        yield
      rescue IOStreams::Errors::InvalidHeader
        true
      end

      # Warn once per reader, since the same columns usually apply to every record.
      def warn_restriction
        @warned = true
        IOStreams.logger&.warn(
          "allowed_columns and required_columns are not applied to this input, but would change the records read. " \
          "In v3.0 they will apply to every input. Set `IOStreams.enforce_column_restrictions = true` to apply them now."
        )
      end
    end
  end
end
