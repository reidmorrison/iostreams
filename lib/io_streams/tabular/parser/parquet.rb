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

        # Returns [false] the records of a Parquet file all have the keys of its columns, so a missing column is checked
        # as for CSV, see `IOStreams::Tabular::Parser::Base.keys_vary?`.
        def self.keys_vary?
          false
        end

        # Returns [IOStreams::Parquet::Clocks|nil] the times of day of the columns that the schema of the file, which the
        # block returns, declares as `time`, which hold their clocks without a zone, read in the zone of the field of the
        # schema that the supplied Proc returns that reads each one, see `IOStreams::Parquet::Clocks.declared`, or nil
        # when it returns none, which reads them in UTC, as the reader of the file returns them.
        def self.clocks(reading)
          IOStreams::Parquet::Clocks.declared(yield, reading)
        end

        # Returns [false] a row of a Parquet file is a record, also when its every value is null, as a row of a database
        # query is, since the file holds no blank lines, so that a read of only some of its columns, see
        # `IOStreams::Schema#projection`, reads the same records as a read of every column, and as its slices.
        def self.blank_rows?
          false
        end

        # Returns [Hash] the record supplied, or the row supplied, an Array that is already parsed, as it is, see
        # `IOStreams::Tabular#record_parse`.
        def parse(row)
          return row if row.is_a?(::Hash) || row.is_a?(::Array)

          raise(IOStreams::Errors::TypeMismatch, "Format is :parquet. Invalid input: #{row.class.name}")
        end
      end
    end
  end
end
