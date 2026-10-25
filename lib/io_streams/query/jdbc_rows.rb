# frozen_string_literal: true

module IOStreams
  class Query
    # The rows of a statement that the raw connection of an adapter of AR-JDBC, on JRuby, runs with `execute_query_raw`,
    # which yields the raw values of each row to a block as it reads them from the result of the driver of the database,
    # rather than returning a result that a source can step through. So that a source of AR-JDBC reads them as the other
    # sources read theirs, see `IOStreams::Query::SOURCES`, the statement runs on a thread of its own, which hands over
    # its rows a batch at a time, in step with the caller: #start runs the statement and reads its first batch, so that
    # a statement that fails, or cannot start, raises before any row is yielded, and #each yields each row from the row
    # after the last one that it yielded, so that a second traversal continues where the first stopped, reading the next
    # batch only once the caller asks for it, so that the statement never uses the connection while the block that the
    # rows are yielded to does, such as on a connection of SQLite that the read shares with the caller.
    #
    # The thread is never interrupted, so that an interrupt of the caller, such as a `Timeout`, reaches the caller while
    # it waits for a batch, rather than the driver, whose statement AR-JDBC would close as the interrupt left it, which
    # for some drivers reads the rest of the result, see `IOStreams::Query::MysqlJdbc`. The rows can be read on any
    # thread, as those of the other sources can.
    #
    # The thread only runs the driver, through the raw connection, never Active Record, so it leases no connection of
    # the pool.
    #
    # AR-JDBC runs a statement again after a failure of the driver that it deems transient or recoverable, unless the
    # connection has a transaction open, which would yield every row again, so a source whose driver raises those once
    # rows were yielded runs the statement in a transaction, see `IOStreams::Query::MysqlJdbc`.
    class JdbcRows
      # The most rows that the thread hands over at a time, so that handing them over costs little: measured on JRuby 10.0
      # reading 300,000 rows of SQLite, 0.52 s in batches of 1,000, 2.45 s a row at a time, and 0.50 s with the rows
      # yielded straight from `execute_query_raw`. The first batch is the first row, and each one after it twice the
      # size of the one before, up to BATCH_SIZE, see #read, so that a statement starts once its first row is read, as
      # the statements of the other sources do, and the block sees the first rows of a slow query as it returns them,
      # rather than once it has returned BATCH_SIZE of them, which a block that leaves early would wait for.
      BATCH_SIZE = 1_000

      # What the thread throws to end the statement before it has yielded every row, see #close.
      STOP = Object.new.freeze
      private_constant :STOP

      # Parameters:
      #   raw: [ActiveRecord::ConnectionAdapters::JdbcConnection]
      #     The raw connection of the connection that the query is read on, see `IOStreams::Query#open`.
      def initialize(raw)
        @raw     = raw
        @thread  = nil
        # Guards what the thread and the caller hand each other, see #hand_over and #next_batch.
        @lock    = Thread::Mutex.new
        @changed = Thread::ConditionVariable.new
        # What the thread hands over: a batch of rows, whether it is the last, and the failure of the statement.
        @handed  = nil
        @last    = false
        @error   = nil
        # Whether the caller asks for the next batch, which the thread waits for after each batch but the last, and
        # whether the caller ended the statement, see #close.
        @wanted  = true
        @closed  = false
        # What the caller took: the rows of the batch that it has not yielded, whether it was the last, and the failure.
        @batch   = []
        @done    = false
        @failure = nil
      end

      # Runs the statement that the supplied statement describes, with the SQL that Active Record runs for the query,
      # within its instrumentation, and the binds as Active Record sends them, see `IOStreams::Query::Statement`, reads
      # its first batch of rows, see #each, and checks the number of values of its first row against the supplied
      # columns, see `IOStreams::Query::Columns#check_width`, since AR-JDBC yields the values of each row without the
      # names of the columns.
      #
      # Raises the exception that AR-JDBC raises, an `ActiveRecord::JDBCError`, for a statement that fails, or cannot
      # start.
      def start(statement, columns)
        statement.instrument do |sql, _values|
          @thread = Thread.new { read(sql, statement.binds) }
          next_batch
        end
        columns.check_width(@batch.first.size) unless @batch.empty?
        self
      end

      # Yields [Array] the raw values of each row, as AR-JDBC returns them, from the row after the last one that it
      # yielded, asking for each batch after the first once the rows of the one before are taken, and releasing each row
      # as it yields it.
      #
      # Raises the exception that AR-JDBC raises for a statement that fails while its rows are read, and again for each
      # traversal after it.
      def each
        loop do
          yield(@batch.shift) until @batch.empty?
          break if @done

          next_batch
        end
      end

      # Returns [true|false] whether the statement may still be reading its result: it started, and has rows that it has
      # not handed over, since it neither handed over its last rows, nor was ended, see #close, nor failed.
      def reading?
        !@thread.nil? && !@done && !@closed && !@failure
      end

      # Ends the statement, which AR-JDBC closes as it leaves the block of `execute_query_raw`, when its rows were not
      # all read, such as when the block that they are yielded to leaves with `break` or an exception, and waits for the
      # thread to finish, so that the connection is no longer used once it returns. The thread ends the statement once
      # the driver returns the row that it is reading, which for a slow query waits for the database, unless the source
      # stopped the driver first, see `IOStreams::Query::MysqlJdbc#discard`.
      def close
        return unless @thread

        @lock.synchronize do
          @closed = true
          @changed.broadcast
        end
        @thread.join
      end

      private

      # Runs the statement within the thread, handing over its rows a batch at a time, see BATCH_SIZE, until it has
      # yielded every row, or failed, or the caller ended it, see #close, when it leaves the block of
      # `execute_query_raw`, so that AR-JDBC closes it, at the next row, rather than once it has read the batch. A
      # failure of the statement is handed over to the caller, which raises it.
      def read(sql, binds)
        batch = []
        size  = 1
        catch(STOP) do
          each_raw(sql, binds) do |values|
            throw(STOP) if @closed
            batch << values
            next if batch.size < size

            hand_over(batch)
            batch = []
            size  = [size * 2, BATCH_SIZE].min
          end
          finish(batch)
        end
      rescue Exception => e # rubocop:disable Lint/RescueException -- the caller raises it, see #next_batch
        finish([], e)
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

      # Hands the supplied batch of rows over to the caller, within the thread, and waits until the caller asks for the
      # next one, see #next_batch, or throws STOP once the caller ended the statement, see #close.
      def hand_over(batch)
        @lock.synchronize do
          @handed = batch
          @wanted = false
          @changed.broadcast
          @changed.wait(@lock) until @wanted || @closed
          throw(STOP) if @closed
        end
      end

      # Hands the last batch of rows over to the caller, within the thread, or the failure of the statement.
      def finish(batch, error = nil)
        @lock.synchronize do
          @handed = batch
          @last   = error.nil?
          @error  = error
          @changed.broadcast
        end
      end

      # Takes the next batch of rows that the thread hands over, asking for it unless the thread already did, such as
      # after an interrupt of the caller while it waited for it, so that no batch is taken twice, or lost.
      #
      # Raises the failure of the statement, also once it was raised.
      def next_batch
        raise(@failure) if @failure

        @lock.synchronize do
          until @handed
            @wanted = true
            @changed.broadcast
            @changed.wait(@lock)
          end
          @batch   = @handed
          @done    = @last
          @failure = @error
          @handed  = nil
        end
        raise(@failure) if @failure
      end
    end
  end
end
