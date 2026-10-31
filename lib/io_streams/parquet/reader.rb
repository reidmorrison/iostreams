# frozen_string_literal: true

module IOStreams
  module Parquet
    # Reads the rows of a Parquet file, each one as a Hash of its typed values by the names of its columns, such as an
    # Integer, BigDecimal, Date, Time, or an Array or Hash for a nested column. A time of day of a column of the file is a
    # Time on 2000-01-01, see `IOStreams::Schema::Field.time_of_day`, rather than on the day that the `parquet` gem reads
    # it.
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

      # Yields [Hash<String, Object>] each row, by the names of its columns, in the order of the columns, with each time of
      # day on 2000-01-01, see #time_columns.
      #
      # Raises the RuntimeError of the parquet gem, tagged as `IOStreams::Errors::Corrupt`, for a file that it cannot
      # read, see .failure_kind.
      #
      # The gem calls the block for each row itself, so it cannot be called within `.tag_failure`, which would tag what
      # the block raises. The gem raises what the block raised, the same object, so an exception is only tagged when the
      # block is not running.
      def each(&block)
        in_block = false
        times    = time_columns
        ::Parquet.each_row(@file_name, columns: @columns) do |row|
          times.each { |name| (time = row[name]) && (row[name] = Schema::Field.time_of_day(time)) }
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

      # Returns [IOStreams::Schema] the schema that the file declares, see `IOStreams::Stream#infer_schema`: a field for
      # each of its columns, in order, of the type that #each reads its values as, which it records at its end, so that
      # no row is read:
      #   integer:  an integer column of any width, signed or not.
      #   number:   a decimal, with the `decimals` of its scale, or a float or double, with `floatNumber: true`.
      #   boolean, date, datetime (a timestamp, or the INT96 of older writers), time and string (text, an enum or JSON).
      #   array:    a list.
      #   object:   a map or a struct.
      #   any:      binary, and any other column.
      # A column that cannot be null, `REQUIRED`, is required, `constraints: {required: true}`, unless its values are text
      # or of type "any", which can be empty, as for the columns of a query, see `IOStreams::Query::Columns`.
      def declared_schema
        IOStreams::Schema.new(fields: fields.map { |field| declared_field(field) })
      end

      private

      # The type of a field of the logical type of a column, see #declared_schema.
      LOGICAL_TYPES = {
        "Integer"   => "integer",
        "Date"      => "date",
        "Timestamp" => "datetime",
        "Time"      => "time",
        "String"    => "string",
        "Enum"      => "string",
        "Json"      => "string",
        "List"      => "array",
        "Map"       => "object"
      }.freeze

      # The type of a field of the converted type of a column of an older writer without a logical type.
      CONVERTED_TYPES = {
        "UTF8" => "string", "ENUM" => "string", "JSON" => "string", "DATE" => "date", "TIMESTAMP_MILLIS" => "datetime",
        "TIMESTAMP_MICROS" => "datetime", "TIME_MILLIS" => "time", "TIME_MICROS" => "time", "LIST" => "array",
        "MAP" => "object", "MAP_KEY_VALUE" => "object"
      }.freeze

      # The type of a field of the physical type of a column without a logical or converted type.
      PHYSICAL_TYPES = {
        "BOOLEAN" => "boolean", "INT32" => "integer", "INT64" => "integer", "INT96" => "datetime", "FLOAT" => "number",
        "DOUBLE" => "number"
      }.freeze

      # The types of field whose values can be empty, so that a column of them that cannot be null is not required.
      EMPTY_TYPES = %w[string any].freeze
      private_constant :LOGICAL_TYPES, :CONVERTED_TYPES, :PHYSICAL_TYPES, :EMPTY_TYPES

      # Returns [Hash] the descriptor of the field of a column, as the `parquet` gem describes it, see #declared_schema.
      def declared_field(column)
        logical   = column.dig("logical_type", "type")
        converted = column["converted_type"]
        scale     = column.dig("logical_type", "scale") || column["scale"]
        decimal   = logical == "Decimal" || (logical.nil? && converted == "DECIMAL")
        type      =
          if decimal then "number"
          elsif column["type"] == "group" then LOGICAL_TYPES[logical] || CONVERTED_TYPES.fetch(converted, "object")
          else LOGICAL_TYPES[logical] || CONVERTED_TYPES[converted] || PHYSICAL_TYPES.fetch(column["physical_type"], "any")
          end

        field = {name: column["name"], type: type}
        if decimal
          field[:decimals] = scale if scale.is_a?(Integer) && !scale.negative?
        elsif type == "number"
          field[:floatNumber] = true
        end
        field[:constraints] = {required: true} if column["repetition"] == "REQUIRED" && !EMPTY_TYPES.include?(type)
        field
      end

      # Returns [Array<String>] the names of the columns of the file, in order, which it records at its end, so that
      # they are known before any row is read.
      def labels
        fields.map { |field| field["name"] }
      end

      # Returns [Array<String>] the names of the columns of times of day that are read, whose values the `parquet` gem
      # reads as a Time on the day that it reads them, in UTC, which #each moves to 2000-01-01, as Active Record holds a
      # time of day, so that a value reads the same on every day. Only a column of the file itself, not a time of day
      # within a column of structs or lists, which IOStreams does not write.
      def time_columns
        names = fields.filter_map { |field| field["name"] if field.dig("logical_type", "type") == "Time" }
        @columns ? names & @columns : names
      end

      # Returns [Array<Hash>] the columns of the file, as the `parquet` gem describes them, read once from its end.
      def fields
        @fields ||= self.class.tag_failure { ::Parquet.metadata(@file_name) }["schema"]["fields"]
      end
    end
  end
end
