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

      # Returns [Module] `IOStreams::Errors::Corrupt` for the RuntimeError that the parquet gem raises for a file that it
      # cannot read, such as one that is not Parquet, or is damaged or cut short, see `IOStreams::Reader.failure_kind`.
      #
      # The gem raises a plain RuntimeError for every failure, without a class of its own, so an exception of a subclass,
      # such as `Timeout::Error`, is not the gem's, and an OS error, whose message the gem ends with "(os error N)", is
      # not a failure of the data. The gem only reads a local file, which Ruby has already opened, so a failure of the
      # storage is raised, and tagged, before it.
      def self.failure_kind(exception)
        return unless exception.instance_of?(::RuntimeError)
        return if exception.message.match?(/\(os error \d+\)/)

        Errors::Corrupt
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
      #
      # Raises the RuntimeError of the parquet gem, tagged as `IOStreams::Errors::Corrupt`, for a file that it cannot
      # read, see .failure_kind.
      #
      # The gem calls the block for each row itself, so it cannot be called within `.tag_failure`, which would tag what
      # the block raises. The gem raises what the block raised, the same object, so an exception is only tagged when the
      # block is not running.
      def each(&block)
        in_block = false
        ::Parquet.each_row(@file_name, columns: @columns) do |row|
          in_block = true
          block.call(row)
          # Not reset in an ensure, which would clear it before the exception that the block raised reaches the rescue.
          in_block = false
        end
        nil
      rescue StandardError => e
        raise if in_block

        kind = self.class.failure_kind(e)
        raise(kind ? kind.tag(e) : e)
      end

      private

      # Returns [Array<String>] the names of the columns of the file, in order, which it records at its end, so that
      # they are known before any row is read.
      def labels
        self.class.tag_failure { ::Parquet.metadata(@file_name) }["schema"]["fields"].map { |field| field["name"] }
      end
    end
  end
end
