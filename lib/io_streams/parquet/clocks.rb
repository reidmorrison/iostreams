# frozen_string_literal: true

module IOStreams
  module Parquet
    # The times of day of the rows of a Parquet file, read in the zone of the `time` field that reads each of their
    # columns. A column of times of day holds the clock that a schema wrote, without a zone, see
    # `IOStreams::Parquet::Column`, which the reader of the file returns as a time of day on 2000-01-01 in UTC, see
    # `IOStreams::Parquet::Reader#each`, and which a slice of its rows holds as it is. The tabular that parses the rows,
    # of the file or of a slice, reads each one in the zone of its field, see `IOStreams::Tabular#read_declared` and
    # `IOStreams::Schema::Field#time_of_clock`, so that a time of day written in New York reads back as the same time,
    # and a schema or contract reads a slice as it reads the file.
    class Clocks
      # Returns [IOStreams::Parquet::Clocks|nil] the times of day of the columns that the supplied schema of the file
      # declares as `time`, such as the schema that a slice of its rows carries, see `IOStreams::Slice#schema`, read by
      # the `time` fields of the schema that the supplied Proc returns, which the tabular chooses, see
      # `IOStreams::Tabular#read_declared`, called only when the file declares such a column, or nil when it returns
      # none, or no `time` field reads one of them.
      def self.declared(declared, reading)
        names = declared.fields.filter_map { |field| field.name if field.type == "time" }
        return if names.empty?

        schema = reading.call
        return unless schema

        clocks = new(names, schema)
        clocks unless clocks.empty?
      end

      # Parameters
      #   columns: [Array<String>]
      #     The names of the columns of times of day.
      #
      #   schema: [IOStreams::Schema]
      #     The schema that reads the rows, whose `time` field of a column reads its clocks in its zone, or in UTC without
      #     one. A column that no `time` field reads is left as it is.
      def initialize(columns, schema)
        @fields = columns.filter_map do |name|
          field = schema.field_for(name, "column")
          [name, field] if field&.type == "time"
        end
      end

      # Returns [true|false] whether no `time` field reads a column of times of day.
      def empty?
        @fields.empty?
      end

      # Returns [Hash] a copy of the row, by the names of its columns, with each time of day read in the zone of its
      # field, or the row itself when none changes, such as for a field without a zone, which reads the clock of a time
      # of day on 2000-01-01 as it is, or when it is not a Hash, so that a row of a slice, which the slice keeps as it is,
      # is copied only when it must be.
      def read(row)
        return row unless row.is_a?(::Hash)

        copy = nil
        @fields.each do |name, field|
          time = row[name]
          next unless time.is_a?(::Time)

          clock = field.time_of_clock(time)
          (copy ||= row.dup)[name] = clock unless clock.equal?(time)
        end
        copy || row
      end
    end
  end
end
