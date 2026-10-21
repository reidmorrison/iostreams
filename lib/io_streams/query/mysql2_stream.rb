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
    # the protocol of MySQL needs, which takes a moment for a large query, at millions of rows a second.
    class Mysql2Stream
      # The `net_write_timeout` of the session while the rows are read, in seconds.
      NET_WRITE_TIMEOUT = 3600

      # The error number of mysql2 for a query on a connection that is still streaming a result: CR_COMMANDS_OUT_OF_SYNC.
      OUT_OF_SYNC = 2014

      # The query options of mysql2 that stream a result, rather than load all of it, as Arrays of the raw values of its
      # columns, on top of those of the connection, which Active Record sets, so that the values are those that `pluck`
      # casts.
      STREAM = {stream: true, cache_rows: false, as: :array}.freeze

      # Returns [true|false] whether the connection is to MySQL through the mysql2 gem, unlike trilogy, whose queries
      # return every row at once.
      def self.reads?(connection)
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
      end

      # Yields [IOStreams::Query::Mysql2Stream] itself, whose #each yields the rows, once the statement of the query is
      # open: run on the raw connection with the SQL and binds that Active Record runs for the query, see
      # `IOStreams::Query::Statement`, its first row read, and the names of its columns checked against those that the
      # query was described by, see `IOStreams::Query::Columns#check`, so that a query that fails, or cannot start,
      # raises before the block is called. The result is freed, and the `net_write_timeout` of the session set back, when
      # the block finishes, or is left with `break` or an exception.
      #
      # Returns the result of the block.
      def open(statement, columns)
        previous = net_write_timeout
        self.net_write_timeout = NET_WRITE_TIMEOUT
        finished = false
        begin
          raw    = @connection.raw_connection
          fields = statement.instrument { |sql, values| stream(raw, sql, values) }
          columns.check(fields)
          result   = yield self
          finished = true
          result
        ensure
          @result&.free
          restore(previous, finished)
        end
      end

      # Yields [Array] each row of the result, its raw values as the mysql2 gem returns them, from the row after the last
      # one that it yielded, so that a second traversal continues where the first stopped, as the lines of a file do.
      #
      # Raises ArgumentError, whose cause is the exception that the block raised, when the block queries the database on
      # the connection that streams the rows, which raises "Commands out of sync", so that the message says why, and
      # what to do instead. It can, when the block shares the connection that the query is read on, such as the pinned
      # connection of the transactional tests of Rails.
      def each(&)
        if @first
          row    = @first
          @first = nil
          yield row
        end
        return if @done

        @result.each(&)
        @done = true
      rescue StandardError => e
        raise unless out_of_sync?(e)

        raise(ArgumentError, "The block cannot query MySQL on the connection that the rows of a query are read on, since " \
                             "mysql2 streams them on it, and it cannot run another query until every row is read, such " \
                             "as the pinned connection of transactional tests. Read the query in batches instead, such " \
                             "as with `IOStreams.stream(relation.in_batches(of: 10_000))`: #{e.message}")
      end

      private

      # Returns [Array<String>] the names of the columns of the result of the SQL, which mysql2 streams, once its first
      # row is read, see #first_row.
      #
      # Raises ArgumentError for the values of binds, which Active Record sends only when the connection prepares
      # statements, which a connection of mysql2 does not by default, since mysql2 cannot stream a prepared statement
      # whose columns hold text: it raises that their data was truncated, as it reads a row at a time from a cursor of
      # the server.
      def stream(raw, sql, values)
        unless values.empty?
          raise(ArgumentError, "IOStreams cannot stream a query on a connection of mysql2 that prepares statements, " \
                               "since mysql2 cannot stream a prepared statement: set `prepared_statements: false`, the " \
                               "default of mysql2, for the connection")
        end

        @result = raw.query(sql, **STREAM)
        # Before any row, since mysql2 frees the result of a query that it streams once it has read every row.
        fields = @result.fields
        @first = first_row
        fields
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

      # Returns [true|false] whether the exception, or the exception of mysql2 that caused it, is the error of a query on
      # a connection that is still streaming a result.
      def out_of_sync?(exception)
        return false unless defined?(::Mysql2::Error)

        [exception, exception.cause].any? { |error| error.is_a?(::Mysql2::Error) && error.error_number == OUT_OF_SYNC }
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
