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
      def self.file(file_name)
        Parquet.load_dependency
        yield new(file_name)
      end

      def initialize(file_name)
        super(nil)
        @file_name = file_name
        @read_only = nil
      end

      # Returns [Array<String>] the names of the columns of the file, in order, which it records at its end, so that
      # they are known before any row is read.
      def labels
        @labels ||= ::Parquet.metadata(@file_name)["schema"]["fields"].map { |field| field["name"] }
      end

      # Reads only the supplied columns, so that the others are neither read nor decoded, since a Parquet file stores
      # each column on its own.
      #
      # Parameters:
      #   labels: [Array<String>]
      #     Columns of the file, see #labels.
      #
      # Raises ArgumentError for a label that is not a column of the file, since the gem would return records without
      # it, rather than raise.
      def read_only(labels)
        unknown = labels - self.labels
        raise(ArgumentError, "Not columns of the Parquet file: #{unknown.map(&:inspect).join(', ')}") unless unknown.empty?

        @read_only = labels
      end

      # Yields [Hash<String, Object>] each row, by the names of its columns, in the order of the columns.
      def each(&)
        ::Parquet.each_row(@file_name, columns: @read_only, &)
        nil
      end
    end
  end
end
