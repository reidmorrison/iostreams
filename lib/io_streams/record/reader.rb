module IOStreams
  module Record
    # Converts each line of an input stream into hash for every row
    class Reader < IOStreams::Reader
      include Enumerable

      # Read a record at a time from a line stream
      # Note:
      # - The supplied stream _must_ already be a line stream, or a stream that responds to :each
      def self.stream(line_reader, original_file_name: nil, **args, &block)
        # Pass-through if already a record reader
        return block.call(line_reader) if line_reader.is_a?(self.class)

        yield new(line_reader, **args)
      end

      # When reading from a file also add the line reader stream
      def self.file(file_name, original_file_name: file_name, delimiter: $/, **args)
        IOStreams::Line::Reader.file(file_name, original_file_name: original_file_name, delimiter: delimiter) do |io|
          yield new(io, **args)
        end
      end

      # Create a Tabular reader to return the stream as Hash records
      # Parse a delimited data source.
      #
      # Parameters
      #   delimited: [#each]
      #     Anything that returns one line / record at a time when #each is called on it.
      #
      #   format: [Symbol]
      #     :csv, :hash, :array, :json, :psv, :fixed
      #
      #   For all other parameters, see Tabular::Header.new
      def initialize(line_reader, cleanse_header: true, **args)
        unless line_reader.respond_to?(:each)
          raise(ArgumentError, "Stream must be a IOStreams::Line::Reader or implement #each")
        end

        @tabular        = IOStreams::Tabular.new(**args)
        @line_reader    = line_reader
        @cleanse_header = cleanse_header
      end

      def each
        @line_reader.each do |line|
          if @tabular.header?
            @tabular.parse_header(line)
            @tabular.cleanse_header! if @cleanse_header
          else
            yield @tabular.record_parse(line)
          end
        end
      end
    end
  end
end
