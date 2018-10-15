module IOStreams
  module Record
    # Example, implied header from first record:
    #   IOStreams.record_writer do |stream|
    #     stream << {name: 'Jack', address: 'Somewhere', zipcode: 12345}
    #     stream << {name: 'Joe', address: 'Lost', zipcode: 32443, age: 23}
    #   end
    #
    # Output:
    #   name, add
    #
    class Writer
      # Write a record as a Hash at a time to a file or stream.
      def self.open(file_name_or_io, delimiter: $/, encoding: nil, encode_cleaner: nil, encode_replace: nil, **args)
        if file_name_or_io.is_a?(String)
          IOStreams.line_writer(file_name_or_io,
                                delimiter:      delimiter,
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

      # Create a Tabular writer that takes individual
      # Parse a delimited data source.
      #
      # Parameters
      #   delimited: [#<<]
      #     Anything that accepts a line / record at a time when #<< is called on it.
      #
      #   format: [Symbol]
      #     :csv, :hash, :array, :json, :psv, :fixed
      #
      #   For all other parameters, see Tabular::Header.new
      #
      #     columns: nil, allowed_columns: nil, required_columns: nil, skip_unknown: true)
      def initialize(delimited, columns: nil, **args)
        @tabular   = IOStreams::Tabular.new(columns: columns, **args)
        @delimited = delimited

        # Render header line when `columns` is supplied.
        @delimited << @tabular.render_header if columns && @tabular.requires_header?
      end

      def <<(hash)
        raise(ArgumentError, 'Must supply a Hash') unless hash.is_a?(Hash)
        if @tabular.header?
          # Extract header from the keys from the first row when not supplied above.
          @tabular.header.columns = hash.keys
          @delimited << @tabular.render_header
        end
        @delimited << @tabular.render(hash)
      end
    end
  end
end
