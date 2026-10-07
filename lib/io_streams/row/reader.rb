module IOStreams
  module Row
    # Converts each line of an input stream into an array for every line
    class Reader < IOStreams::Reader
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
      def self.stream(line_reader, original_file_name: nil, cleanse_header: true, **args)
        # Pass-through if already a row reader
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
      #     Whether to cleanse the header row, see `IOStreams::Tabular::Header#cleanse!`.
      #     Default: true
      def initialize(line_reader, tabular:, cleanse_header: true)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular        = tabular
        @line_reader    = line_reader
        @cleanse_header = cleanse_header
        @warned         = false

        # Supplied columns take the place of a header row, so apply the allowed and required columns to them.
        restrict_columns if restricted? && !@tabular.header?
      end

      # Yields the header row as it was read, followed by each row.
      #
      # The allowed and required columns are applied to the header row, or to the supplied columns,
      # even when `cleanse_header` is false, unless `IOStreams.enforce_column_restrictions?` is false.
      # Each row still contains every value.
      def each
        @line_reader.each do |line|
          if @tabular.header?
            columns = @tabular.parse_header(line)
            if @cleanse_header
              cleanse_columns
            elsif restricted?
              restrict_columns
            end
            yield columns
          else
            yield @tabular.row_parse(line)
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

        header = @tabular.header
        copy   = IOStreams::Tabular::Header.new(
          columns:          header.columns,
          allowed_columns:  header.allowed_columns,
          required_columns: header.required_columns,
          skip_unknown:     header.skip_unknown
        )
        changed =
          begin
            copy.cleanse!(rename: @cleanse_header)
            copy.columns != header.columns
          rescue IOStreams::Errors::InvalidHeader
            true
          end
        warn_restriction if changed
      end

      # Warn once per reader.
      def warn_restriction
        @warned = true
        IOStreams.logger&.warn(
          "allowed_columns and required_columns are not applied to this input since " \
          "`IOStreams.enforce_column_restrictions` is false, but would change the header row read."
        )
      end
    end
  end
end
