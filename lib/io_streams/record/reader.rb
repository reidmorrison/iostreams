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
      #     Whether to cleanse the header row read, see `IOStreams::Tabular::Header#cleanse!`, which the tabular that it
      #     creates does, see `IOStreams::Tabular.new`.
      #     With a schema it raises ArgumentError, even when nil, since the fields of the schema name the keys of the
      #     records instead.
      #     Default: cleanses it.
      #
      #   tabular: [IOStreams::Tabular]
      #     The tabular that parses each line, such as one with a schema, see `IOStreams::Stream#schema`, in place of the
      #     other options, which create it.
      #
      #   report_repeated_key: [true|false]
      #     Whether to report a deprecation warning, before the first record, when two columns of the header row are the
      #     same key, see #warn_repeated_key, which `IOStreams::Stream#each` and `#reader` ask for, rather than another
      #     gem that creates a reader, which its users cannot change.
      #     Default: false
      #
      # Note:
      # * `allowed_columns`, `required_columns` and `skip_unknown` only apply to every input, including JSON records,
      #   supplied `columns` and `cleanse_header: false`, when `IOStreams.enforce_column_restrictions?` is true.
      def initialize(line_reader, original_file_name: nil, tabular: nil, report_repeated_key: false, **args)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        if tabular && (original_file_name || !args.empty?)
          raise(ArgumentError, "Supply either tabular: or the options that create it, not both")
        end

        @tabular             = tabular || IOStreams::Tabular.new(file_name: original_file_name, **args)
        @line_reader         = line_reader
        @report_repeated_key = report_repeated_key

        # Supplied columns take the place of a header row, so apply the allowed and required columns to them.
        @tabular.restrict_columns
      end

      # Yields each record, after the header row, which names their keys, see `IOStreams::Tabular#read_record_line`.
      def each(&block)
        return each_reporting(&block) if @report_repeated_key

        @line_reader.each { |line| @tabular.read_record_line(line, &block) }
      end

      # Writes each record to the writer, see `IOStreams::Record::Writer`, as a copy with a schema does, see
      # `IOStreams::Stream#copy_from`. A blank line, or a JSON line of null, which #each yields as nil, is not a record,
      # so it is not written.
      #
      # Returns the result of #each.
      def copy_to(writer)
        each { |record| writer << record unless record.nil? }
      end

      private

      # Yields each record, as #each does, after reporting a deprecation warning before the first one when two columns
      # of the header row are the same key, see #warn_repeated_key.
      def each_reporting
        @line_reader.each do |line|
          @tabular.read_record_line(line) do |record|
            warn_repeated_key if @report_repeated_key
            yield record
          end
        end
      end

      # Reports a deprecation warning, once, when two columns of the header row are the same key, see
      # `IOStreams::Tabular#repeated_key`, such as a header row of `a,a,b`, or of `A` and `a`, which are cleansed to the
      # same key, since each record holds the value of only the last of them, while IOStreams v3.0 raises
      # `IOStreams::Errors::InvalidHeader` for them, rather than lose the others.
      def warn_repeated_key
        @report_repeated_key = false
        key = @tabular.repeated_key
        return if key.nil?

        Deprecation.warn("records read from a header row whose columns are the same key, #{key.inspect}, are " \
                         "deprecated, since each record holds the value of only the last of them, and v3.0 raises " \
                         "IOStreams::Errors::InvalidHeader for them: rename the columns, or read the rows with " \
                         "each(:array), which holds every column")
      end
    end
  end
end
