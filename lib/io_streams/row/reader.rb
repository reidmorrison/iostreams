module IOStreams
  module Row
    # Converts each line of an input stream into an array for every line
    class Reader < IOStreams::Reader
      # Read a line as an Array at a time from a stream.
      # Note:
      # - The supplied stream _must_ already be a line stream, or a stream that responds to :each
      def self.stream(line_reader, **args)
        # Pass-through if already a row reader
        return yield(line_reader) if line_reader.is_a?(self.class)

        yield new(line_reader, **args)
      end

      # When reading from a file also add the line reader stream
      def self.file(file_name, original_file_name: file_name, delimiter: $/, **args)
        IOStreams::Line::Reader.file(file_name, delimiter: delimiter) do |io|
          yield new(io, original_file_name: original_file_name, **args)
        end
      end

      # Create a Tabular reader to return the stream rows as arrays.
      #
      # Parameters
      #   delimited: [#each]
      #     Anything that returns one line / record at a time when #each is called on it.
      #
      #   format: [Symbol]
      #     :csv, :hash, :array, :json, :psv, :fixed
      #
      #   For all other parameters, see Tabular::Header.new
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
