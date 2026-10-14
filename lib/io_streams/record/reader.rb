# frozen_string_literal: true

module IOStreams
  module Record
    # Converts each line of an input stream into hash for every row
    class Reader < IOStreams::Reader
      include Enumerable

      # Returns [Array<Symbol>] the options that this reader accepts, see .stream: its own, and those of the
      # `IOStreams::Tabular` that reads the records, other than the file name, which it supplies.
      def self.option_names
        [:original_file_name, :cleanse_header, *(IOStreams::Tabular.read_option_names - %i[file_name])]
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
      #   cleanse_header: [true|false]
      #     See #initialize.
      #
      #   format: [Symbol]
      #     :csv, :hash, :array, :json, :psv, :fixed
      #
      #   schema: [IOStreams::Schema]
      #     The fields of the file and the type of each one, see `IOStreams::Tabular.new`. The `:fixed` format needs it
      #     for the position of each field. With a schema, `columns`, `allowed_columns`, `required_columns` and
      #     `skip_unknown` raise ArgumentError, since it describes the columns of the file.
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
      #       When supplied any columns that are rejected will be returned in the cleansed columns
      #       as nil so that they can be ignored during processing.
      #
      #   required_columns [Array<String>]
      #     Deprecated: see `constraints` in `IOStreams::Schema::Field`.
      #     List of columns that must be present, otherwise an Exception is raised.
      #
      #   skip_unknown [true|false]
      #     Deprecated: see `fieldsMatch` in `IOStreams::Schema`.
      #     true:
      #       Skip columns not present in the `allowed_columns` by cleansing them to nil.
      #       #as_hash will skip these additional columns entirely as if they were not in the file at all.
      #     false:
      #       Raises Tabular::InvalidHeader when a column is supplied that is not in the whitelist.
      #
      # Note:
      # * `allowed_columns`, `required_columns` and `skip_unknown` apply to every input, including JSON records,
      #   supplied `columns` and `cleanse_header: false`, unless `IOStreams.enforce_column_restrictions?` is false.
      def self.stream(line_reader, original_file_name: nil, cleanse_header: IOStreams::Tabular::CLEANSE_BY_DEFAULT, **args)
        # Pass-through if already a record reader
        return yield(line_reader) if line_reader.is_a?(self)

        tabular = IOStreams::Tabular.new(file_name: original_file_name, **args)
        yield new(line_reader, tabular: tabular, cleanse_header: cleanse_header)
      end

      # When reading from a file also add the line reader stream, which splits the lines where the format expects,
      # such as within a quoted CSV value. See `.stream` for the parameters.
      def self.file(file_name, original_file_name: file_name, delimiter: $/,
                    cleanse_header: IOStreams::Tabular::CLEANSE_BY_DEFAULT, **args)
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
      #     Deprecated. Whether to cleanse the header row, see `IOStreams::Tabular::Header#cleanse!`. With a schema, the
      #     keys of the records are the names of its fields instead, so it raises ArgumentError, see
      #     `IOStreams::Tabular#header_cleansing`.
      #     Default: true
      def initialize(line_reader, tabular:, cleanse_header: IOStreams::Tabular::CLEANSE_BY_DEFAULT)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular        = tabular
        @line_reader    = line_reader
        @cleanse_header = tabular.header_cleansing(cleanse_header)

        # Supplied columns take the place of a header row, so apply the allowed and required columns to them.
        @tabular.restrict_columns(rename: @cleanse_header)
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
