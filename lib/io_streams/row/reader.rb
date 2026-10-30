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
      #   For all other parameters, see IOStreams::Tabular.new
      def initialize(line_reader, original_file_name: nil, tabular: nil, **args)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        if tabular && (original_file_name || !args.empty?)
          raise(ArgumentError, "Supply either tabular: or the options that create it, not both")
        end

        @tabular     = tabular || IOStreams::Tabular.new(file_name: original_file_name, **args)
        @line_reader = line_reader
      end

      # Returns [true|false] whether the first row that #each yields is a header row, which names the column of each
      # value of the rows after it, see `IOStreams::Tabular#rows_header?`: the header row of the file, or with a schema,
      # the names of its fields, of a file without one, such as fixed width or JSON. False when the columns were
      # supplied, which name the values of the rows instead. Asked before #each.
      def header?
        @tabular.rows_header?
      end

      # Returns [true|false] whether the rows that #each yields are the records of the file, Hashes rather than Arrays,
      # see `IOStreams::Tabular#record_rows?`, such as those of JSON without a schema.
      def record_rows?
        @tabular.record_rows?
      end

      # Yields each row, an Array, after the header row of a file with one, which it yields first, see
      # `IOStreams::Tabular#read_row`. With a schema, the header row is an `IOStreams::Row::HeaderRow` of the names of
      # the fields, also for a file without a header row, such as fixed width or JSON.
      def each(&block)
        @line_reader.each { |line| @tabular.read_row(line, &block) }
      end

      # Writes each row to the writer, see `IOStreams::Row::Writer`, as a copy with a schema does, see
      # `IOStreams::Stream#copy_from`, telling it the column of each value of the rows: the header row of the file, or
      # for a file without one, the names of the fields of its schema, is an `IOStreams::Row::HeaderRow`, which the writer
      # takes as the header row of the rows after it, see `IOStreams::Row::Writer#<<`, so that a target with a schema
      # matches its columns to the fields, rather than write it as a row of values. Tabular decides which row is the
      # header row, see `IOStreams::Tabular#start_copy` and `IOStreams::Tabular#copy_row`. A blank line, which is not a
      # row, is not written.
      #
      # Returns the result of the #each of the line reader.
      def copy_to(writer)
        @tabular.start_copy { |columns| writer << columns }
        @line_reader.each { |line| @tabular.copy_row(line) { |row| writer << row unless row.nil? } }
      end
    end
  end
end
