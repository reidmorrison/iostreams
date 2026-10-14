# frozen_string_literal: true

module IOStreams
  class Tabular
    module Parser
      # The records of a Parquet file, which are typed values by the names of their columns, like the records of the
      # `:hash` format, but read and written by `IOStreams::Parquet::Reader` and `IOStreams::Parquet::Writer`, rather
      # than as lines of text, see `.row_format`.
      class Parquet < Hash
        # Returns [Module] the format that reads and writes the records of a Parquet file.
        def self.row_format
          IOStreams::Parquet
        end

        def parse(row)
          return row if row.is_a?(::Hash)

          raise(IOStreams::Errors::TypeMismatch, "Format is :parquet. Invalid input: #{row.class.name}")
        end
      end
    end
  end
end
