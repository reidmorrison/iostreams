# frozen_string_literal: true

module IOStreams
  class Query
    # Reads the rows of a query on SQLite one at a time, with a statement of the sqlite3 gem, which steps through the
    # result rather than load all of it, see `IOStreams::Query`.
    class SqliteStatement
      # Returns [true|false] whether the connection is to SQLite through the sqlite3 gem, which this source reads with,
      # unlike an adapter of SQLite on JRuby.
      def self.reads?(connection)
        return false unless connection.adapter_name == "SQLite" && defined?(::SQLite3::Database)

        connection.raw_connection.is_a?(::SQLite3::Database)
      end

      # Returns [Module] the kind of failure that an exception raised by the sqlite3 gem means, or nil when it is none of
      # them: `Unavailable` for a database that another connection has locked, and `PermissionDenied` for an access that
      # it does not permit.
      def self.failure_kind(exception)
        return unless defined?(::SQLite3::Exception) && exception.is_a?(::SQLite3::Exception)

        case exception
        when ::SQLite3::BusyException, ::SQLite3::LockedException then Errors::Unavailable
        when ::SQLite3::PermissionException, ::SQLite3::AuthorizationException then Errors::PermissionDenied
        end
      end

      # Parameters:
      #   connection: [ActiveRecord::ConnectionAdapters::SQLite3Adapter]
      #     The connection that the query is read on, which the caller holds while it is read.
      def initialize(connection)
        @connection = connection
      end

      # Yields [Array] each row of the result of the SQL, its raw values as the sqlite3 gem returns them, once the names
      # of its columns are checked against those that the query was described by, see
      # `IOStreams::Query::Columns#check`. The statement is closed when the block finishes, or is left with `break` or an
      # exception.
      def each(sql, columns, &)
        statement = @connection.raw_connection.prepare(sql)
        columns.check(statement.columns)
        statement.each(&)
      ensure
        statement&.close
      end
    end
  end
end
