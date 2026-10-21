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
        @statement  = nil
        @first      = nil
      end

      # Yields [IOStreams::Query::SqliteStatement] itself, whose #each yields the rows, once the statement of the query
      # is open: prepared on the connection with the SQL and binds that Active Record runs for the query, see
      # `IOStreams::Query::Statement`, stepped to its first row, and the names of its columns checked against those
      # that the query was described by, see `IOStreams::Query::Columns#check`, so that a statement that fails, or
      # cannot start, raises before the block is called. The statement is closed when the block finishes, or is left
      # with `break` or an exception.
      #
      # Returns the result of the block.
      def open(statement, columns)
        binds      = statement.type_casted_binds
        @statement = @connection.raw_connection.prepare(statement.sql)
        @statement.bind_params(binds) unless binds.empty?
        @first = @statement.step
        columns.check(@statement.columns)
        yield self
      ensure
        @statement&.close
        @statement = nil
      end

      # Yields [Array] each row of the result, its raw values as the sqlite3 gem returns them, from the row after the last
      # one that it yielded, so that a second traversal continues where the first stopped, as the lines of a file do.
      def each
        while (row = next_row)
          yield row
        end
      end

      private

      # Returns [Array|nil] the next row of the result: the first one, which #open stepped to, then each one after it, or
      # nil once every row has been read, since the statement then stays done.
      def next_row
        row    = @first
        @first = nil
        row || @statement.step
      end
    end
  end
end
