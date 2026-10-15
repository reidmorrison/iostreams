# frozen_string_literal: true

module IOStreams
  module Parquet
    # Reads the rows of a Parquet file, each one as a Hash of its typed values by the names of its columns, such as an
    # Integer, BigDecimal, Date, Time, or an Array or Hash for a nested column.
    #
    # A Parquet file records its columns at its end, so it is read from a file, and any other input is first copied
    # into a temp file, see `IOStreams::Reader.stream`.
    class Reader < IOStreams::Reader
      def self.option_names
        []
      end

      # Yields [IOStreams::Parquet::Reader] the reader of the rows of the file.
      #
      # Parameters:
      #   schema: [IOStreams::Schema|nil]
      #     The fields of the records, see `IOStreams::Tabular#read_rows`. With a schema whose `fieldsMatch` skips the
      #     columns that it does not list, only the columns of its fields are read, see `IOStreams::Schema#projection`,
      #     since a Parquet file stores each column on its own. The schema is not an option of the stream, since it is set
      #     on the path, see `IOStreams::Stream#schema`, as for the writer, see `IOStreams::Parquet::Writer.file`.
      #     Default: nil, which reads every column.
      def self.file(file_name, schema: nil)
        Parquet.load_dependency
        yield new(file_name, schema)
      end

      def initialize(file_name, schema = nil)
        super(nil)
        @file_name = file_name
        @columns   = schema&.projection { labels }
      end

      # Yields [Hash<String, Object>] each row, by the names of its columns, in the order of the columns.
      def each(&)
        ::Parquet.each_row(@file_name, columns: @columns, &)
        nil
      end

      private

      # Returns [Array<String>] the names of the columns of the file, in order, which it records at its end, so that
      # they are known before any row is read.
      def labels
        ::Parquet.metadata(@file_name)["schema"]["fields"].map { |field| field["name"] }
      end
    end
  end
end
