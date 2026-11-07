# frozen_string_literal: true

module IOStreams
  module Parquet
    # The times of day of the rows of a Parquet file: the values of its columns of times of day, which hold the clock
    # that a schema wrote, without a zone, see `IOStreams::Parquet::Column`, read as a time of day on 2000-01-01 in the
    # zone of the `time` field of the schema that reads each column, so that a time of day written in New York reads
    # back as the same time, see `IOStreams::Schema::Field#time_of_clock`, otherwise in UTC, see
    # `IOStreams::Schema::Field.time_of_day`.
    #
    # The reader of the file reads them so, see `IOStreams::Parquet::Reader`, and so does the stream of a slice of its
    # rows, see `IOStreams::Slice::Stream#open_rows`, whose rows hold the clocks of the file, so that a schema or
    # contract reads a slice as it reads the file.
    class Clocks
      # Returns [IOStreams::Parquet::Clocks|nil] the times of day of the columns that the supplied schema of the file
      # declares as `time`, such as the schema that a slice of its rows carries, see `IOStreams::Slice#schema`, read by
      # the fields of the supplied schema, or nil when it declares none.
      def self.declared(declared, schema)
        names = declared&.fields&.filter_map { |field| field.name if field.type == "time" }
        new(names, schema) unless names.nil? || names.empty?
      end

      # Parameters
      #   columns: [Array<String>]
      #     The names of the columns of times of day.
      #
      #   schema: [IOStreams::Schema|nil]
      #     The schema that reads the rows, whose `time` field of a column reads its clocks in its zone, or nil to read
      #     every clock in UTC, as the file holds it.
      def initialize(columns, schema)
        @fields = columns.map do |name|
          field = schema&.field_for(name, "column")
          [name, (field if field&.type == "time")]
        end
      end

      # Returns [Hash] the row, by the names of its columns, with each time of day read, see the class, changing the
      # row supplied, such as one that the reader of the file has just read.
      def read!(row)
        @fields.each { |name, field| (time = row[name]).is_a?(::Time) && (row[name] = time_of_day(time, field)) }
        row
      end

      # Returns [Hash] a copy of the row with each time of day read, see #read!, or the row itself when it holds none, or
      # is not a Hash, such as a row of a slice, which the slice keeps as it is.
      def read(row)
        return row unless row.is_a?(::Hash) && @fields.any? { |name, _field| row[name].is_a?(::Time) }

        read!(row.dup)
      end

      private

      # Returns [Time] the time of day of the clock of the time, in the zone of the field, or in UTC without one.
      def time_of_day(time, field)
        field ? field.time_of_clock(time) : Schema::Field.time_of_day(time)
      end
    end
  end
end
