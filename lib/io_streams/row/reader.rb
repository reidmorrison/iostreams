# frozen_string_literal: true

module IOStreams
  module Row
    # Converts each line of an input stream into an array for every line
    class Reader < IOStreams::Reader
      # Returns [Array<Symbol>] the options that this reader accepts, see .stream: its own, and those of the
      # `IOStreams::Tabular` that reads the rows, other than the file name, which it supplies.
      def self.option_names
        [:original_file_name, :cleanse_header, *(IOStreams::Tabular.read_option_names - %i[file_name])]
      end

      # Read a line as an Array at a time from a stream.
      # Note:
      # - The supplied stream _must_ already be a line stream, or a stream that responds to :each
      #
      # Parameters
      #   original_file_name: [String]
      #     The file name from which to infer the format, see `IOStreams::Tabular.new`.
      #
      #   cleanse_header: [true|false]
      #     See #initialize.
      #
      #   For all other parameters, see `IOStreams::Tabular.new`.
      def self.stream(line_reader, original_file_name: nil, cleanse_header: IOStreams::Tabular::CLEANSE_BY_DEFAULT, **args)
        # Pass-through if already a row reader
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

      # Create a reader that returns the stream rows as arrays.
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

      # Yields the header row as it was read, followed by each row.
      #
      # The allowed and required columns are applied to the header row, or to the supplied columns,
      # even when `cleanse_header` is false, unless `IOStreams.enforce_column_restrictions?` is false.
      # Each row still contains every value.
      #
      # With a schema, the header row is the names of the fields of its columns, and each row is the values of those
      # fields, in the order of the fields, without the columns that the schema skips, see `IOStreams::Tabular#row_parse`.
      def each
        @line_reader.each do |line|
          if @tabular.header?
            yield @tabular.read_header(line, cleanse: @cleanse_header)
          else
            yield @tabular.row_parse(line)
          end
        end
      end
    end
  end
end
