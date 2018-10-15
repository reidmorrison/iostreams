require 'csv'
module IOStreams
  module Row
    # Example:
    #   IOStreams.row_writer do |stream|
    #     stream << ['name', 'address', 'zipcode']
    #     stream << ['Jack', 'Somewhere', 12345]
    #     stream << ['Joe', 'Lost', 32443]
    #   end
    #
    # Output:
    #   ...
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
            yield new(io, **args)
          end
        else
          yield new(file_name_or_io, **args)
        end
      end

      # Create a Tabular writer that takes individual rows as arrays.
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
        delimited << @tabular.render_header if columns && @tabular.requires_header?
      end

      # Supply a hash or an array to render
      def <<(array)
        raise(ArgumentError, 'Must supply an Array') unless array.is_a?(Array)
        if @tabular.header?
          # If header (columns) was not supplied as an argument, assume first line is the header.
          @tabular.header.columns = array
          @delimited << @tabular.render_header
        else
          @delimited << @tabular.render(array)
        end
      end
    end
  end
end
