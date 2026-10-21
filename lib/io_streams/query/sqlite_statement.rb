# frozen_string_literal: true

module IOStreams
  class Query
    # Reads the rows of a query on SQLite one at a time, with a statement of the sqlite3 gem, which steps through the
    # result rather than load all of it, see `IOStreams::Query`.
    class SqliteStatement
      # Returns [true|false] whether the connection is to SQLite through the sqlite3 gem, which this source reads with,
      # unlike an adapter of SQLite on JRuby, which cannot load the gem, a C extension. It does not ask the raw
      # connection, which Active Record would no longer verify or reconnect until it is checked in again, since it is
      # asked of the connection of the caller too, see `IOStreams::Query#columns`.
      def self.reads?(connection)
        connection.adapter_name == "SQLite" && defined?(::SQLite3::Database) ? true : false
      end

      # Returns [true|false] whether the database of the connection can be read on a connection of its own, while the
      # block that the rows are yielded to writes on another, see `IOStreams::Query#open`: a database in WAL mode, the
      # default of Rails, whose readers each read a snapshot of it, which the writes of another connection neither
      # change nor wait for. Not a database whose journal is a rollback journal, whose readers keep the writes of every
      # other connection waiting until they finish, nor an in-memory database, which is a database of its own on each
      # connection, unless its cache is shared, when a reader locks its tables against the writes of the others.
      def self.own_connection?(connection)
        connection.raw_connection.journal_mode == "wal"
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

      # Returns [Array<String>] the types of field whose columns that are `NOT NULL` always have a value once Active Record
      # casts it, see `IOStreams::Query::Columns`: none, since a column of SQLite holds a value of any type, which Active
      # Record casts to nil when it is not one of the type of the column, such as empty text in an integer, decimal or
      # boolean column, or text that is not a date in a date column.
      def self.requirable_types
        [].freeze
      end

      # Returns [String] the type of field of a column of a type that Active Record does not know, see
      # `IOStreams::Query::Columns`: "any", since SQLite gives a type only to a column of a table, so that a column that
      # the query computes holds values of any type, such as an Integer or a Float.
      def self.unknown_type
        "any"
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
        raw    = @connection.raw_connection
        @first = statement.instrument do |sql, binds|
          @statement = raw.prepare(sql)
          @statement.bind_params(binds) unless binds.empty?
          @statement.step
        end
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
