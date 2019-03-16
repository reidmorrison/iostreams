module IOStreams
  module Record
    # Converts each line of an input stream into hash for every row
    class Reader
      include Enumerable

      # Read a record as a Hash at a time from a file or stream.
      def self.open(file_name_or_io, delimiter: nil, buffer_size: 65536, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args)
        if file_name_or_io.is_a?(String)
          IOStreams.line_reader(file_name_or_io,
                                delimiter:      delimiter,
                                buffer_size:    buffer_size,
                                encoding:       encoding,
                                encode_cleaner: encode_cleaner,
                                encode_replace: encode_replace
          ) do |io|
            yield new(io, file_name: file_name_or_io, **args)
          end
        else
          yield new(file_name_or_io, **args)
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
        @tabular        = IOStreams::Tabular.new(**args)
        @line_reader      = line_reader
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
