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
        IOStreams::Line::Reader.file(file_name, original_file_name: original_file_name, delimiter: delimiter) do |io|
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
      end

      def each
        @line_reader.each do |line|
          if @tabular.header?
            columns = @tabular.parse_header(line)
            @tabular.cleanse_header! if @cleanse_header
            yield columns
          else
            yield @tabular.row_parse(line)
          end
        end
      end
    end
  end
end
