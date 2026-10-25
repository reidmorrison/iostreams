# frozen_string_literal: true

module IOStreams
  class Query
    # Reads the rows of a query on SQLite one at a time with the SQLite adapter of AR-JDBC, on JRuby, which cannot load
    # the sqlite3 gem, a C extension, that `IOStreams::Query::SqliteStatement` reads with, whose answers about SQLite it
    # shares, such as `.requirable_types`. Its driver, sqlite-jdbc, steps through the result rather than load all of it,
    # and AR-JDBC yields each row as the driver reads it, see `IOStreams::Query::JdbcRows`.
    class SqliteJdbc < SqliteStatement
      # The kind of failure of each primary result code of SQLite, which sqlite-jdbc raises as the error code of its
      # exception, as `IOStreams::Query::SqliteStatement.failure_kind` tells apart the exceptions of the sqlite3 gem.
      RESULT_KINDS = {
        5  => Errors::Unavailable,      # SQLITE_BUSY, a database that another connection has locked
        6  => Errors::Unavailable,      # SQLITE_LOCKED, a table that another connection has locked
        3  => Errors::PermissionDenied, # SQLITE_PERM, an access that the database does not permit
        23 => Errors::PermissionDenied  # SQLITE_AUTH, an access that the authorizer does not permit
      }.freeze

      # Returns [true|false] whether the connection is to SQLite through the SQLite adapter of AR-JDBC, see
      # `IOStreams::Query::Jdbc.adapter?`.
      def self.reads?(connection)
        connection.adapter_name == "SQLite" && Jdbc.adapter?(connection)
      end

      # Returns [true|false] whether the database of the connection can be read on a connection of its own, see
      # `IOStreams::Query::SqliteStatement.own_connection?`: a database in WAL mode, which the raw connection of the
      # read is asked, as the sqlite3 gem is, so that the question is not logged as a statement of the application.
      def self.own_connection?(connection)
        mode = nil
        connection.raw_connection.execute_query_raw("PRAGMA journal_mode") { |value| mode = value }
        mode.to_s.casecmp?("wal")
      end

      # Returns [Module] the kind of failure that an exception of sqlite-jdbc means, see RESULT_KINDS, or nil when it is
      # none of them, or another driver raised it.
      def self.failure_kind(exception)
        failure = Jdbc.driver_exception(exception, "org.sqlite.")
        return unless failure

        RESULT_KINDS[failure.error_code & 0xFF] if failure.is_a?(::Java::JavaSql::SQLException)
      end

      # Yields [IOStreams::Query::SqliteJdbc] itself, whose #each yields the rows, once the statement of the query is
      # open: run on the raw connection with the SQL and binds that Active Record runs for the query, its first rows
      # read, and the number of their values checked against the columns that the query was described by, see
      # `IOStreams::Query::JdbcRows#start`, so that a statement that fails, or cannot start, raises before the block is
      # called. The statement is closed when the block finishes, or is left with `break` or an exception, once the
      # driver has read the batch of rows that it is reading.
      #
      # Returns the result of the block.
      def open(statement, columns)
        @rows = JdbcRows.new(@connection.raw_connection)
        @rows.start(statement, columns)
        yield self
      ensure
        @rows&.close
      end

      # Yields [Array] each row of the result, its raw values as AR-JDBC returns them, from the row after the last one
      # that it yielded, so that a second traversal continues where the first stopped, as the lines of a file do.
      def each(&)
        @rows.each(&)
      end
    end
  end
end
