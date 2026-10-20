# frozen_string_literal: true

module IOStreams
  class Query
    # Reads the rows of a query on PostgreSQL with a cursor, which fetches FETCH_SIZE rows at a time, so that the whole
    # result is never in memory, see `IOStreams::Query`.
    #
    # It runs through the public API of Active Record, so that each statement is logged, with the query transformers of
    # Active Record applied, its result is typed by PostgreSQL, and it works with any driver of PostgreSQL. It declares
    # the cursor with the SQL and binds that Active Record runs for the query, see `IOStreams::Query::Statement`, which
    # PostgreSQL takes as the parameters of `DECLARE`.
    #
    # A cursor needs a transaction, which it opens on the connection that the query is read on, one of its own, see
    # `IOStreams::Query#open`, so that the statements of the block that the rows are yielded to, which run on the
    # connection of the caller, are not part of it. The connection of the read has a transaction open only in the
    # transactional tests of Rails, whose connection the pool shares with the read, so the read runs in a savepoint of
    # their transaction, which a read that fails rolls back, rather than their transaction.
    #
    # Within the transaction it sets:
    #   cursor_tuple_fraction = 1.0
    #     So that PostgreSQL plans the query to return every row, as it plans a query that is not a cursor, rather than
    #     its first 10%, which can choose a slower plan for the whole result.
    #   idle_in_transaction_session_timeout = 0
    #     So that a target that is slow to write, such as an upload, does not leave the transaction idle for long
    #     enough that PostgreSQL closes the connection.
    # They end with the transaction, and are set back to what they were in a transaction that was already open. The
    # `statement_timeout` of the connection, such as one that the `variables` of the configuration of the database set,
    # applies to each fetch, rather than to the whole query.
    class PostgresqlCursor
      # The number of rows of each fetch.
      FETCH_SIZE = 10_000

      # The settings of the transaction that reads the query, see above.
      SETTINGS = {"cursor_tuple_fraction" => "1.0", "idle_in_transaction_session_timeout" => "0"}.freeze

      # The types of field whose columns that are `NOT NULL` always have a value once Active Record casts it, see
      # .requirable_types.
      REQUIRABLE_TYPES = %w[integer number boolean date datetime].freeze

      # The kind of failure of each exception of the pg gem that a statement can raise, which Active Record does not tag
      # itself, see `IOStreams::Query::Failure`.
      FAILURE_KINDS = {
        InsufficientPrivilege: Errors::PermissionDenied,
        AdminShutdown:         Errors::Unavailable,
        CrashShutdown:         Errors::Unavailable,
        UnableToSend:          Errors::Unavailable
      }.freeze

      # The kind of failure that the message of `PG::ConnectionBad` means, for a connection that could not be made, which
      # libpq reports in its message, such as `password authentication failed for user "jack"`. A host that does not
      # resolve, such as a mistyped host, is neither, unless name resolution failed for the time being, as for a path,
      # see `IOStreams::Errors::Unavailable.unknown_host?`.
      CONNECTION_KINDS = {
        Errors::PermissionDenied => Regexp.union(
          /password authentication failed/, /no pg_hba\.conf entry/, /role ".*" does not exist/, /no password supplied/
        ),
        Errors::Unavailable      => Regexp.union(
          /Connection refused/, /timeout expired/, /timed out/, /could not connect to server/,
          /server closed the connection unexpectedly/, /Connection reset/, /Network is unreachable/, /No route to host/,
          /the database system is (?:starting up|shutting down|in recovery mode|not yet accepting connections)/,
          /too many clients already/, /too many connections/, /remaining connection slots are reserved/,
          /Temporary failure in name resolution/, /SSL SYSCALL error/
        )
      }.freeze

      # Returns [true|false] whether the connection is to PostgreSQL.
      def self.reads?(connection)
        connection.adapter_name == "PostgreSQL"
      end

      # Returns [true] whether the database of the connection can be read on a connection of its own, see
      # `IOStreams::Query#open`: PostgreSQL always can, since the cursor reads a snapshot of the database, which the
      # statements of the block on another connection neither change nor wait for.
      def self.own_connection?(_connection)
        true
      end

      # Returns [Array<String>] the types of field whose columns that are `NOT NULL` always have a value once Active Record
      # casts it, see `IOStreams::Query::Columns`: a column of PostgreSQL holds only values of its type, which Active Record
      # casts to a value, such as a date or time of 'infinity' to `Float::INFINITY`, rather than nil.
      def self.requirable_types
        REQUIRABLE_TYPES
      end

      # Returns [Module] the kind of failure that an exception raised by the pg gem means, or nil when it is none of
      # them: `PermissionDenied` for a table or column that the user may not read, or credentials that the server does
      # not accept, and `Unavailable` for a server that cannot be reached, ended the query, or has no connection free,
      # see FAILURE_KINDS and CONNECTION_KINDS.
      def self.failure_kind(exception)
        return unless defined?(::PG::Error) && exception.is_a?(::PG::Error)

        if exception.is_a?(::PG::ConnectionBad)
          message = exception.message
          return CONNECTION_KINDS.find { |_kind, pattern| pattern.match?(message) }&.first
        end

        FAILURE_KINDS.find { |name, _kind| exception.is_a?(::PG.const_get(name)) }&.last
      end

      # Parameters:
      #   connection: [ActiveRecord::ConnectionAdapters::PostgreSQLAdapter]
      #     The connection that the query is read on, which the caller holds while it is read.
      def initialize(connection)
        @connection = connection
        @name       = "iostreams_cursor_#{object_id}"
        @rows       = []
        @done       = false
      end

      # Yields [IOStreams::Query::PostgresqlCursor] itself, whose #each yields the rows, once the cursor of the query is
      # open: declared, within a transaction, see above, with the SQL and binds that Active Record runs for the query, see
      # `IOStreams::Query::Statement`, its first rows fetched, and the names of its columns checked against those that
      # the query was described by, see `IOStreams::Query::Columns#check`, so that a query that fails, or cannot start,
      # raises before the block is called.
      #
      # The cursor is closed when the block finishes, or is left with `break` or an exception, and the settings are set
      # back, unless the database failed, which aborts the transaction, see #restore.
      #
      # Returns the result of the block.
      def open(statement, columns)
        joined = @connection.transaction_open?
        @connection.transaction(requires_new: true) do
          previous = joined ? current_settings : nil
          finished = false
          begin
            apply_settings(SETTINGS)
            declare(statement)
            fetch(columns)
            result   = yield self
            finished = true
            result
          ensure
            restore(previous, finished)
          end
        end
      end

      # Yields [Array] each row of the result, its raw values as Active Record returns them, from the row after the last
      # one that it yielded, so that a second traversal continues where the first stopped, as the lines of a file do: the
      # rows of the last fetch that are left, then those of each fetch after it, until a fetch returns fewer rows than it
      # asked for.
      def each
        loop do
          while (row = @rows.shift)
            yield row
          end
          break if @done

          fetch
        end
      end

      private

      # Declares the cursor of the query, with its binds, through Active Record, which applies its query transformers,
      # and reports the statement by the name of that of a query, see `IOStreams::Query::Statement::NAME`, as a source
      # that reads with its driver reports it.
      def declare(statement)
        sql = "DECLARE #{@name} NO SCROLL CURSOR FOR #{statement.sql}"
        uncached { @connection.exec_query(sql, Statement::NAME, statement.binds) }
      end

      # Fetches the next FETCH_SIZE rows of the cursor, whose rows #each yields, and checks the names of the columns of
      # its result against the supplied columns, see `IOStreams::Query::Columns#check`, for the first fetch. Once a
      # fetch returns fewer rows than it asked for, there are none left to fetch.
      def fetch(columns = nil)
        result = uncached { @connection.select_all("FETCH FORWARD #{FETCH_SIZE} FROM #{@name}", "IOStreams Fetch") }
        columns&.check(result.columns)
        @rows = result.rows
        @done = @rows.size < FETCH_SIZE
      end

      # Closes the cursor, and sets back the settings of the transaction that was already open. A failure to do so is
      # raised only when every row was read, so that it never replaces the exception that left the block.
      def restore(previous, finished)
        run("CLOSE #{@name}")
        apply_settings(previous) if previous
      rescue StandardError
        raise if finished
      end

      # Returns [Hash<String, String>] the value of each of the SETTINGS in the transaction.
      def current_settings
        names  = SETTINGS.keys
        values = uncached do
          @connection.select_rows("SELECT #{names.map { |name| "current_setting('#{name}')" }.join(', ')}", "IOStreams")
        end.first
        names.zip(values).to_h
      end

      # Sets each of the settings for the rest of the transaction.
      def apply_settings(settings)
        assignments = settings.map do |name, value|
          "set_config(#{@connection.quote(name)}, #{@connection.quote(value)}, true)"
        end
        uncached { @connection.select_rows("SELECT #{assignments.join(', ')}", "IOStreams") }
      end

      # Runs a statement of the cursor.
      def run(sql)
        uncached { @connection.execute(sql, "IOStreams") }
      end

      # Yields without the query cache, which would return the same rows for each fetch, and without clearing the query
      # cache of the application, which Active Record does for a statement that it runs with `#execute`.
      def uncached(&)
        @connection.uncached(dirties: false, &)
      end
    end
  end
end
