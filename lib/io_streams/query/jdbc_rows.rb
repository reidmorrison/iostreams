# frozen_string_literal: true

module IOStreams
  class Query
    # The rows of a statement that the raw connection of an adapter of AR-JDBC, on JRuby, runs with `execute_query_raw`,
    # which yields the raw values of each row to a block as it reads them from the result of the driver of the database,
    # rather than returning a result that a source can step through. So that a source of AR-JDBC reads them as the other
    # sources read theirs, see `IOStreams::Query::SOURCES`, the statement runs in a Fiber, which hands over its rows a
    # batch at a time: #start runs the statement and reads its first batch, so that a statement that fails, or cannot
    # start, raises before any row is yielded, and #each yields each row from the row after the last one that it yielded,
    # so that a second traversal continues where the first stopped.
    #
    # The Fiber only runs the driver, through the raw connection, never Active Record, so it leases no connection of the
    # pool, which Active Record within an external enumerator would leak, see lib/io_streams/query/CLAUDE.md.
    class JdbcRows
      # The most rows that the Fiber hands over at a time, so that switching to it costs little: measured on JRuby 10.0
      # reading 300,000 rows of SQLite, 0.52 s in batches of 1,000, 2.45 s a row at a time, and 0.50 s with the rows
      # yielded straight from `execute_query_raw`. The first batch is the first row, and each one after it twice the
      # size of the one before, up to BATCH_SIZE, see #read, so that a statement starts once its first row is read, as
      # the statements of the other sources do, and the block sees the first rows of a slow query as it returns them,
      # rather than once it has returned BATCH_SIZE of them, which a block that leaves early would wait for.
      BATCH_SIZE = 1_000

      # What the Fiber returns once the statement has yielded every row.
      DONE = Object.new.freeze
      private_constant :DONE

      # What the Fiber is resumed with to end the statement before it has yielded every row, see #close.
      STOP = Object.new.freeze
      private_constant :STOP

      # Parameters:
      #   raw: [ActiveRecord::ConnectionAdapters::JdbcConnection]
      #     The raw connection of the connection that the query is read on, which is one of its own, see
      #     `IOStreams::Query#open`.
      def initialize(raw)
        @raw   = raw
        @fiber = nil
        @batch = []
        @index = 0
        @done  = false
        @width = nil
      end

      # Runs the statement of the supplied SQL, with the supplied binds, as Active Record sends them, see
      # `IOStreams::Query::Statement#binds`, and reads its first batch of rows, see #each.
      #
      # Raises the exception that AR-JDBC raises, an `ActiveRecord::JDBCError`, for a statement that fails, or cannot
      # start.
      def start(sql, binds)
        @fiber = Fiber.new { read(sql, binds) }
        next_batch
        @width = @batch.first&.size
        self
      end

      # Yields [Array] the raw values of each row, as AR-JDBC returns them, from the row after the last one that it
      # yielded, reading each batch after the first once the rows of the one before are taken, and releasing each row as
      # it yields it.
      def each
        loop do
          while @index < @batch.size
            row            = @batch[@index]
            @batch[@index] = nil
            @index        += 1
            yield row
          end
          break if @done

          next_batch
        end
      end

      # Returns [true|false] whether the statement is still reading its result: it started, and has rows that it has not
      # yielded, since it neither yielded every row, nor was ended, see #close, nor failed.
      def reading?
        !@done && !@fiber.nil? && @fiber.alive?
      end

      # Returns [Integer|nil] the number of values of each row, one for each column of the result, once the statement
      # started, see #start, or nil when it has no row. AR-JDBC yields the values of each row without the names of the
      # columns, so that this is all that is known of them.
      attr_reader :width

      # Ends the statement, which AR-JDBC closes as it leaves the block of `execute_query_raw`, when its rows were not
      # all read, such as when the block that they are yielded to leaves with `break` or an exception.
      def close
        return unless reading?

        @done = true
        @fiber.resume(STOP)
      end

      private

      # Runs the statement within the Fiber, handing over its rows a batch at a time, see BATCH_SIZE, until it has
      # yielded every row, or the Fiber is resumed with STOP, see #close, when it leaves the block of
      # `execute_query_raw`.
      #
      # Returns DONE.
      def read(sql, binds)
        batch = []
        size  = 1
        catch(STOP) do
          each_raw(sql, binds) do |values|
            batch << values
            next if batch.size < size

            throw(STOP) if Fiber.yield(batch).equal?(STOP)
            batch = []
            size  = [size * 2, BATCH_SIZE].min
          end
          throw(STOP) if !batch.empty? && Fiber.yield(batch).equal?(STOP)
        end
        DONE
      end

      # Yields [Array] the raw values of each row of the statement: a plain statement without binds, otherwise a
      # prepared statement, which AR-JDBC sets each of the binds of.
      def each_raw(sql, binds, &block)
        if binds.empty?
          @raw.execute_query_raw(sql) { |*values| block.call(values) }
        else
          @raw.execute_query_raw(sql, binds) { |*values| block.call(values) }
        end
      end

      # Takes the next batch of rows from the Fiber, or none once it has yielded every row.
      def next_batch
        batch  = @fiber.resume
        @index = 0
        if batch.equal?(DONE)
          @done  = true
          @batch = []
        else
          @batch = batch
        end
      end
    end
  end
end
