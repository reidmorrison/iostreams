# frozen_string_literal: true

module IOStreams
  module Parquet
    # Writes the records of a Parquet file, whose columns, and the type of each one, are the fields of the schema, see
    # `IOStreams::Parquet::Column`.
    #
    # The `parquet` gem writes the rows that it pulls from an Enumerator, while records are pushed to this writer with
    # #<<, so the gem writes in a thread of its own, which takes each row from a queue. The block that writes the records
    # stays in the thread of the caller, so that it can leave early, such as with `break`, which it could not do from
    # within an Enumerator that the gem pulls from. A row group is written once the gem has its rows, so the memory that
    # it holds is bounded, see the `flush_threshold` of `Parquet.write_rows`.
    #
    # A Parquet file records its columns at its end, so it is written to a temp file, then copied to its output, see
    # `.stream`.
    class Writer < IOStreams::Writer
      # The number of rows that the queue holds before #<< waits for the gem to take them.
      QUEUE_SIZE = 1_000

      # Ends the rows that the gem pulls without completing the file, when the block that writes them raises.
      class Abort < StandardError
      end

      # The compression of the columns that the `parquet` gem writes, see `compression:` in `.stream`.
      COMPRESSIONS = %w[none snappy gzip lz4 zstd brotli].freeze

      def self.option_names
        %i[compression]
      end

      # Yields [IOStreams::Parquet::Writer] the writer of the records of the file, then writes the file to the output
      # stream once the block returns, including when it leaves early, such as with `break`, which keeps the records
      # written so far, as it does for a format of lines. Nothing is written when the block raises.
      #
      # The file is written to a temp file, then copied to the output stream, since a Parquet file records its columns at
      # its end.
      #
      # Parameters:
      #   schema: [IOStreams::Schema]
      #     The fields of the records, which are the columns of the file. Required, since Parquet records the type of
      #     every column, which the records do not give. The schema is not an option of the stream, since it is set on
      #     the path, see `IOStreams::Stream#schema`.
      #
      #   compression: [String|Symbol]
      #     How each column is compressed: "none", "snappy", "gzip", "lz4", "zstd" or "brotli". A reader finds it in the
      #     file, so reading ignores it.
      #     Default: "snappy"
      #
      # Returns the result of the block.
      def self.stream(output_stream, schema:, compression: "snappy")
        unless schema
          raise(ArgumentError, "Writing Parquet needs a schema, set with #schema on the path, since a Parquet file records " \
                               "the type of each of its columns")
        end
        compression = compression.to_s
        unless COMPRESSIONS.include?(compression)
          raise(ArgumentError, "Unknown Parquet compression: #{compression.inspect}. " \
                               "Valid compressions: #{COMPRESSIONS.join(', ')}")
        end

        columns = schema.fields.map { |field| Column.new(field) }
        Parquet.load_dependency
        purpose = "the Parquet file, before it is copied to its output"
        Utils.private_temp_file("iostreams_parquet", purpose: purpose) do |file_name|
          writer = new(file_name, columns, compression)
          failed = false
          begin
            yield(writer)
          rescue Exception # rubocop:disable Lint/RescueException -- so that every error ends the thread, and is raised
            failed = true
            writer.abort
            raise
          ensure
            unless failed
              writer.finish
              ::File.open(file_name, "rb") { |source| ::IO.copy_stream(source, output_stream) }
            end
          end
        end
      end

      def initialize(file_name, columns, compression)
        super(nil)
        @columns = columns
        @queue   = SizedQueue.new(QUEUE_SIZE)
        @thread  = start(file_name, {type: :struct, fields: columns.map(&:descriptor)}, compression)
      end

      # Writes a record, whose values are those of the fields, in their order, by their names, and of their types, see
      # `IOStreams::Schema::Columns#render`.
      #
      # Returns self, so that calls can be chained.
      #
      # Raises the error of the gem when it could not write a row before this one.
      def <<(record)
        return self if record.nil?

        push(@columns.map { |column| column.value(record[column.key]) })
        self
      end

      # Waits for the gem to write the file once the rows have all been written.
      #
      # Raises the error of the gem when it could not write the file.
      def finish
        @queue.close
        @thread.value
      end

      # Ends the file without writing it, since writing its records failed.
      def abort
        begin
          @queue.push(Abort.new)
        rescue ClosedQueueError
          nil
        end
        @queue.close
        @thread.join
      rescue StandardError
        # The error of the block that writes the records is raised instead.
        nil
      end

      private

      def start(file_name, schema, compression)
        queue  = @queue
        thread = Thread.new do
          rows = Enumerator.new do |yielder|
            while (row = queue.pop)
              raise(row) if row.is_a?(Abort)

              yielder << row
            end
          end
          ::Parquet.write_rows(rows, schema: schema, write_to: file_name, compression: compression)
        ensure
          # So that #<< raises rather than waits for a thread that will not take its row.
          queue.close
        end
        thread.report_on_exception = false
        thread
      end

      def push(row)
        @queue.push(row)
      rescue ClosedQueueError
        # The gem stopped, so raise its error.
        @thread.value
        raise
      end
    end
  end
end
