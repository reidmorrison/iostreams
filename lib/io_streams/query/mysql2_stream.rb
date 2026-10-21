# frozen_string_literal: true

module IOStreams
  class Query
    # Reads the rows of a query on MySQL one at a time with the mysql2 gem, which streams the result from the server
    # rather than load all of it, see `IOStreams::Query`.
    #
    # The server waits for the client to take each row for at most `net_write_timeout` seconds, 60 by default, before it
    # ends the query, so a target that is slow to write, such as an upload, can lose the connection. So the
    # `net_write_timeout` of the session is NET_WRITE_TIMEOUT while the rows are read, and is set back afterwards.
    #
    # The query is read on a connection of its own, see `IOStreams::Query#open`, since while mysql2 streams a result, its
    # connection cannot run any other query, so that the block that the rows are yielded to queries the database on the
    # connection of the caller. The result is freed when the block finishes, or is left with `break` or an exception,
    # before the connection is used again. Freeing a result that was left early reads the rest of it from the server, as
    # the protocol of MySQL needs, which takes a moment for a large query, at millions of rows a second. A connection that
    # the read shares with the caller, such as the pinned connection of the transactional tests of Rails, is read whole
    # instead, so that the block can query it, see #open.
    class Mysql2Stream
      # The `net_write_timeout` of the session while the rows are read, in seconds.
      NET_WRITE_TIMEOUT = 3600

      # The query options of mysql2 that stream a result, rather than load all of it, as Arrays of the raw values of its
      # columns, on top of those of the connection, which Active Record sets, so that the values are those that `pluck`
      # casts.
      STREAM = {stream: true, cache_rows: false, as: :array}.freeze

      # Returns [true|false] whether the connection is to MySQL through the mysql2 gem, unlike trilogy, whose queries
      # return every row at once, or the MySQL adapter of AR-JDBC on JRuby, which cannot load the gem, but is named
      # "Mysql2" too. It does not ask the connection for its raw connection, which would mark the connection of the
      # caller as used by the application, so that Active Record would no longer verify or reconnect it.
      def self.reads?(connection)
        return false unless defined?(::Mysql2::Client)

        connection.adapter_name == "Mysql2"
      end

      # Returns [true] since a connection of its own reads the query, while the block that the rows are yielded to queries
      # the database on the connection of the caller, which a connection that streams a result could not run.
      def self.own_connection?(_connection)
        true
      end

      # Returns [Module] the kind of failure that an exception raised by the mysql2 gem means, such as while it streams
      # a result, which Active Record does not see, or for a connection that could not be made, see
      # `IOStreams::Query::Failure`, or nil when it is none of them: what MySQL says of its error number, or of its
      # message, since mysql2 raises an error that ends a streamed result without its number, including
      # `IOStreams::Query::Failure::NONE` for a host that does not resolve, see `IOStreams::Query::MysqlFailure`, and
      # `Unavailable` for its own timeout, of the `read_timeout` of the connection, which has no number either.
      def self.failure_kind(exception)
        return unless defined?(::Mysql2::Error) && exception.is_a?(::Mysql2::Error)
        return Errors::Unavailable if exception.is_a?(::Mysql2::Error::TimeoutError) && !exception.error_number

        MysqlFailure.kind(exception.error_number, exception.message)
      end

      # Returns [Array<String>] the types of field whose columns that are `NOT NULL` always have a value once Active Record
      # casts it, see `IOStreams::Query::Columns`: an integer, a number and a boolean, but not a date or a datetime, whose
      # zero value, such as '0000-00-00', which MySQL keeps in a `NOT NULL` column unless its SQL mode forbids it, mysql2
      # returns as nil.
      def self.requirable_types
        %w[integer number boolean].freeze
      end

      # Parameters:
      #   connection: [ActiveRecord::ConnectionAdapters::Mysql2Adapter]
      #     The connection that the query is read on.
      def initialize(connection)
        @connection = connection
        @result     = nil
        @first      = nil
        @done       = false
        @rows       = nil
        @index      = 0
      end

      # Yields [IOStreams::Query::Mysql2Stream] itself, whose #each yields the rows, once the statement of the query is
      # open: run with the SQL that Active Record runs for the query, see `IOStreams::Query::Statement`, its first row
      # read, and the names of its columns checked against those that the query was described by, see
      # `IOStreams::Query::Columns#check`, so that a query that fails, or cannot start, raises before the block is
      # called.
      #
      # On a connection of its own, see `IOStreams::Query#open`, the result is streamed, see #stream. On a connection
      # that has a transaction open, which only one that the read shares with the caller has, such as the pinned
      # connection of the transactional tests of Rails, which `pool.checkout` returns, every row of the result is read
      # before the block is called, see #read_whole, since the block, and the other threads of the application, query
      # the database on that connection, which cannot run another query while mysql2 streams a result.
      #
      # Returns the result of the block.
      def open(statement, columns, &)
        @connection.transaction_open? ? read_whole(statement, columns, &) : stream(statement, columns, &)
      end

      # Yields [Array] each row of the result, its raw values as the mysql2 gem returns them, from the row after the last
      # one that it yielded, so that a second traversal continues where the first stopped, as the lines of a file do.
      def each(&)
        return each_read(&) if @rows

        if @first
          row    = @first
          @first = nil
          yield row
        end
        return if @done

        @result.each(&)
        @done = true
      end

      private

      # Yields itself once the statement streams its result on the raw connection, see #open, with the
      # `net_write_timeout` of the session raised while the rows are read, and set back afterwards. The result is
      # freed when the block finishes, or is left with `break` or an exception.
      def stream(statement, columns)
        previous = net_write_timeout
        self.net_write_timeout = NET_WRITE_TIMEOUT
        finished = false
        begin
          raw    = @connection.raw_connection
          fields = statement.instrument { |sql, values| start(raw, sql, values) }
          columns.check(fields)
          result   = yield self
          finished = true
          result
        ensure
          @result&.free
          restore(previous, finished)
        end
      end

      # Returns [Array<String>] the names of the columns of the result of the SQL, which mysql2 streams, once its first
      # row is read, see #first_row.
      def start(raw, sql, values)
        refuse_binds(values)
        @result = raw.query(sql, **STREAM)
        # Before any row, since mysql2 frees the result of a query that it streams once it has read every row.
        fields = @result.fields
        @first = first_row
        fields
      end

      # Yields itself once every row of the result of the statement is read, see #open, so that the connection is free
      # for other queries while the block runs.
      def read_whole(statement, columns)
        raw    = @connection.raw_connection
        fields = statement.instrument do |sql, values|
          refuse_binds(values)
          result = raw.query(sql, as: :array)
          # Before its rows, since mysql2 frees a result once it has read every row.
          names = result.fields
          @rows = result.to_a
          names
        end
        columns.check(fields)
        yield self
      end

      # Raises ArgumentError for the values of binds, which Active Record sends only when the connection prepares
      # statements, which a connection of mysql2 does not by default, since mysql2 cannot stream a prepared statement
      # whose columns hold text: it raises that their data was truncated, as it reads a row at a time from a cursor of
      # the server.
      def refuse_binds(values)
        return if values.empty?

        raise(ArgumentError, "IOStreams cannot stream a query on a connection of mysql2 that prepares statements, since " \
                             "mysql2 cannot stream a prepared statement: set `prepared_statements: false`, the default " \
                             "of mysql2, for the connection")
      end

      # Yields [Array] each row that was read whole, see #read_whole, from the row after the last one that it yielded.
      def each_read
        while @index < @rows.size
          row     = @rows[@index]
          @index += 1
          yield row
        end
      end

      # Returns [Array|nil] the first row of the result, or nil when it has none, once mysql2 has read it, so that #each
      # yields it first, and every row after it.
      def first_row
        first = nil
        @result.each do |values| # rubocop:disable Lint/UnreachableLoop -- reads the first row, which #each continues after
          first = values
          break
        end
        @done = first.nil?
        first
      end

      # Sets back the `net_write_timeout` of the session. A failure to do so, such as when the connection was lost, is
      # raised only when the block finished, so that it never replaces the exception that left the block.
      def restore(previous, finished)
        self.net_write_timeout = previous
      rescue StandardError
        raise if finished
      end

      def net_write_timeout
        uncached { @connection.select_value("SELECT @@SESSION.net_write_timeout", "IOStreams") }
      end

      def net_write_timeout=(seconds)
        uncached { @connection.execute("SET SESSION net_write_timeout = #{Integer(seconds)}", "IOStreams") }
      end

      # Yields without the query cache, and without clearing the query cache of the application, which Active Record
      # does for a statement that it runs with `#execute`.
      def uncached(&)
        @connection.uncached(dirties: false, &)
      end
    end
  end
end
