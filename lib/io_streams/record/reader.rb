# frozen_string_literal: true

module IOStreams
  module Record
    # Converts each line of an input stream into hash for every row
    class Reader < IOStreams::Reader
      include Enumerable

      # Returns [Array<Symbol>] the options that this reader accepts, see .stream: its own, and those of the
      # `IOStreams::Tabular` that reads the records, other than the file name, which it supplies.
      def self.option_names
        [:original_file_name, *(IOStreams::Tabular.read_option_names - %i[file_name])]
      end

      # Read a record at a time from a line stream
      # Note:
      # - The supplied stream _must_ already be a line stream, or a stream that responds to :each
      #
      # Parameters
      #   original_file_name: [String]
      #     When `:format` is not supplied the file name can be used to infer the required format.
      #     Optional. Default: nil
      #
      #   cleanse_header: [true|false|nil]
      #     Deprecated. Whether to cleanse the header row, see `IOStreams::Tabular.new`.
      #
      #   format: [Symbol]
      #     :csv, :hash, :array, :json, :psv, :fixed or :parquet, see `IOStreams::Tabular.new`.
      #
      #   schema: [IOStreams::Schema]
      #     The fields of the file and the type of each one, see `IOStreams::Tabular.new`. The `:fixed` format needs it
      #     for the position of each field. With a schema, `columns`, `allowed_columns` and `required_columns` raise
      #     ArgumentError unless they are nil, since it describes the columns of the file, while `skip_unknown`, which
      #     only applies to `allowed_columns`, is accepted.
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
      #   allowed_columns [Array<String>]
      #     Deprecated: see `fieldsMatch` in `IOStreams::Schema`.
      #     List of columns to allow.
      #     Default: nil ( Allow all columns )
      #     Note:
      #       When supplied, a column that it rejects is prefixed with `__rejected__`, see
      #       `IOStreams::Tabular::Header::IGNORE_PREFIX`, in the cleansed columns, so that it can be ignored during
      #       processing.
      #
      #   required_columns [Array<String>]
      #     Deprecated: see `constraints` in `IOStreams::Schema::Field`.
      #     List of columns that must be present, otherwise an Exception is raised.
      #
      #   skip_unknown [true|false]
      #     Deprecated: see `fieldsMatch` in `IOStreams::Schema`.
      #     true:
      #       Skip the columns that are not in `allowed_columns`, by prefixing them with `__rejected__`, so that the
      #       records read skip them entirely, as if they were not in the file at all.
      #     false:
      #       Raises IOStreams::Errors::InvalidHeader for a column that is not in `allowed_columns`.
      #
      # Note:
      # * `allowed_columns`, `required_columns` and `skip_unknown` apply to every input, including JSON records,
      #   supplied `columns` and `cleanse_header: false`, unless `IOStreams.enforce_column_restrictions?` is false.
      def self.stream(line_reader, original_file_name: nil, **args)
        # Pass-through if already a record reader
        return yield(line_reader) if line_reader.is_a?(self)

        yield new(line_reader, tabular: IOStreams::Tabular.new(file_name: original_file_name, **args))
      end

      # When reading from a file also add the line reader stream, which splits the lines where the format expects,
      # such as within a quoted CSV value. See `.stream` for the parameters.
      def self.file(file_name, original_file_name: file_name, delimiter: $/, **args)
        tabular = IOStreams::Tabular.new(file_name: original_file_name, **args)
        IOStreams::Line::Reader.file(file_name, delimiter: delimiter, embedded_within: tabular.quote_character) do |io|
          yield new(io, tabular: tabular)
        end
      end

      # Create a reader to return the stream as Hash records.
      #
      # Parameters
      #   line_reader: [#each]
      #     Anything that returns one line / record at a time when #each is called on it.
      #
      #   tabular: [IOStreams::Tabular]
      #     Parses each line in its format, holds the header, and cleanses the header row as its `cleanse_header`
      #     option says, see `IOStreams::Tabular.new`.
      def initialize(line_reader, tabular:)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular     = tabular
        @line_reader = line_reader

        # Supplied columns take the place of a header row, so apply the allowed and required columns to them.
        @tabular.restrict_columns
      end

      # Yields each record, after the header row, which names their keys, see `IOStreams::Tabular#read_record_line`.
      def each(&block)
        @line_reader.each { |line| @tabular.read_record_line(line, &block) }
      end

      # Writes each record to the writer, see `IOStreams::Record::Writer`, as a copy does, see
      # `IOStreams::Stream#copy_from`. A blank line, or a JSON line of null, which #each yields as nil, is not a record,
      # so it is not written.
      #
      # Returns the result of #each.
      def copy_to(writer)
        each { |record| writer << record unless record.nil? }
      end
    end
  end
end
