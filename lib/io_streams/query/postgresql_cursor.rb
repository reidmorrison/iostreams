# frozen_string_literal: true

module IOStreams
  class Query
    # Reads the rows of a query on PostgreSQL with a cursor, which fetches about FETCH_BYTES of its rows at a time, so
    # that the whole result is never in memory, however wide its rows are, see `IOStreams::Query`.
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
    #     enough that PostgreSQL closes the connection, on PostgreSQL 9.6 and later, which have it.
    #   transaction_timeout = 0
    #     So that a `transaction_timeout` of the role, the database or the session does not end the transaction of an
    #     export that takes longer, on PostgreSQL 17 and later, which have it.
    # They end with the transaction, and are set back to what they were in a transaction that was already open. The
    # `statement_timeout` of the connection, such as one that the `variables` of the configuration of the database set,
    # applies to each fetch, rather than to the whole query.
    class PostgresqlCursor
      # The number of rows of the first fetch, by whose size those of the fetches after it are sized, see #next_size.
      FIRST_FETCH = 100

      # The size of the raw values of the rows of each fetch after the first, in bytes, about, see #next_size.
      FETCH_BYTES = 8 * 1024 * 1024

      # The most rows of a fetch, however narrow its rows are, see #next_size.
      MAX_FETCH = 10_000

      # The size of a raw value that is not text, such as an Integer that the driver decoded, in bytes, see #next_size.
      VALUE_BYTES = 8

      # The settings of the transaction that reads the query, see above.
      SETTINGS = {
        "cursor_tuple_fraction"               => "1.0",
        "idle_in_transaction_session_timeout" => "0",
        "transaction_timeout"                 => "0"
      }.freeze

      # The earliest version of PostgreSQL that has each of the SETTINGS that not every version that Active Record reads
      # has, as `server_version_num` numbers it, on which the transaction sets it, see #settings.
      SETTING_VERSIONS = {"idle_in_transaction_session_timeout" => 90_600, "transaction_timeout" => 170_000}.freeze

      # The names of the adapters of Active Record whose databases it reads, see .reads?: that of PostgreSQL, and that of
      # PostGIS, which adds the types of its extension to it, rather than every subclass of the adapter of PostgreSQL,
      # such as that of CockroachDB, whose server may not take the settings of the cursor, see SETTINGS.
      ADAPTERS = %w[PostgreSQL PostGIS].freeze

      # The types of field whose columns that are `NOT NULL` always have a value once Active Record casts it, see
      # .requirable_types.
      REQUIRABLE_TYPES = %w[integer number boolean date datetime time duration array].freeze

      # The kind of failure of each exception of the pg gem that a statement can raise, which Active Record does not tag
      # itself, see `IOStreams::Query::Failure`.
      FAILURE_KINDS = {
        InsufficientPrivilege: Errors::PermissionDenied,
        AdminShutdown:         Errors::Unavailable,
        CrashShutdown:         Errors::Unavailable,
        UnableToSend:          Errors::Unavailable
      }.freeze

      # The start of each attempt to connect that the message of `PG::ConnectionBad` reports, see .connection_kind.
      # libpq tries each address of each host in turn, such as both addresses of `localhost`, and reports why each one
      # failed on a line that starts with the address, `connection to server at "db" (10.0.0.1), port 5432 failed: ` or
      # `connection to server on socket "/tmp/.s.PGSQL.5432" failed: `, from libpq 14, and before it with
      # `could not connect to server: `, or with the error of the server itself, such as
      # `FATAL:  database "orders" does not exist`. A host that does not resolve, which has no address to try, is
      # reported on a line of its own, such as `could not translate host name "db" to address: Name or service not known`.
      ATTEMPT = /^(?=connection to server |could not connect to server|could not translate host name |FATAL:  )/

      # The kind of failure that the message of `PG::ConnectionBad` means, by the last attempt to connect that it reports:
      # the first kind whose pattern the attempt matches, see .connection_kind. `IOStreams::Query::Failure::NONE` is for
      # an attempt that failed for a reason that is neither, so that it is not tagged as Active Record names it: a
      # database that does not exist, and a host that does not resolve, such as a mistyped host, unless name resolution
      # failed for the time being, as for a path, see `IOStreams::Errors::Unavailable::TEMPORARY_RESOLUTION_FAILURE`.
      CONNECTION_KINDS = {
        Errors::PermissionDenied => Regexp.union(
          # Credentials that the server does not accept, such as `password authentication failed for user "jack"`, or the
          # same for another method of authentication, such as peer, ident, PAM, LDAP, RADIUS, certificate, GSSAPI or
          # SSPI, a role that may not log in, or connect to the database, or a host that pg_hba.conf rejects.
          /authentication failed for user/, /no password supplied/, /connection requires a valid client certificate/,
          /no pg_hba\.conf entry/, /pg_hba\.conf rejects /, /role ".*" does not exist/,
          /role ".*" is not permitted to log in/, /permission denied for database/
        ),
        Errors::Unavailable      => Regexp.union(
          /Connection refused/, /timeout expired/, /timed out/, /could not connect to server/,
          /connection to server on socket .* failed: No such file or directory/,
          /server closed the connection unexpectedly/, /Connection reset/,
          # The text of `Errno::ENETUNREACH` and `Errno::EHOSTUNREACH` with glibc and on macOS, and then with musl.
          /Network is unreachable/, /No route to host/, /Network unreachable/, /Host is unreachable/,
          /the database system is (?:starting up|shutting down|in recovery mode|not yet accepting connections)/,
          /too many clients already/, /too many connections/, /remaining connection slots are reserved/,
          /could not translate host name ".*" to address: #{Errors::Unavailable::TEMPORARY_RESOLUTION_FAILURE}/,
          /SSL SYSCALL error/
        ),
        Failure::NONE            => Regexp.union(/could not translate host name /, /database ".*" does not exist/)
      }.freeze

      # Returns [true|false] whether the connection is to PostgreSQL, through an adapter of ADAPTERS, with any driver but
      # the PostgreSQL adapter of AR-JDBC on JRuby, whose values and failures `IOStreams::Query::PostgresqlJdbc` knows.
      def self.reads?(connection)
        ADAPTERS.include?(connection.adapter_name) && !Jdbc.adapter?(connection)
      end

      # Returns [true] whether the database of the connection can be read on a connection of its own, see
      # `IOStreams::Query#open`: PostgreSQL always can, since the cursor reads a snapshot of the database, which the
      # statements of the block on another connection neither change nor wait for.
      def self.own_connection?(_connection)
        true
      end

      # Returns [Array<String>] the types of field whose columns that are `NOT NULL` always have a value once Active Record
      # casts it, see `IOStreams::Query::Columns`: a column of PostgreSQL holds only values of its type, which Active Record
      # casts to a value, such as a date or time of 'infinity' to `Float::INFINITY`, rather than nil, a time of day to a
      # Time and an interval to an `ActiveSupport::Duration`, since a time outside a day, and an infinite interval, which
      # Active Record would cast to nil, raise, see `IOStreams::Query::Columns#cast`, and an array to an Array, which can
      # be empty, as a field of arrays that is required takes it.
      def self.requirable_types
        REQUIRABLE_TYPES
      end

      # Returns [String] the type of field of a column of a type that Active Record does not know, such as `timetz`, see
      # `IOStreams::Query::Columns`: "string", since PostgreSQL returns the value of such a column as its text, which
      # Active Record returns as it is.
      def self.unknown_type
        "string"
      end

      # Returns [Module] the kind of failure that an exception raised by the pg gem means: `PermissionDenied` for a table
      # or column that the user may not read, or credentials, or a host, that the server does not accept, and
      # `Unavailable` for a server that cannot be reached, ended the query, or has no connection free, see FAILURE_KINDS
      # and CONNECTION_KINDS. Returns `IOStreams::Query::Failure::NONE` for a connection that failed for a reason that is
      # neither, such as a host that does not resolve, and nil for any other exception, or a reason that it does not
      # know, which Active Record names.
      def self.failure_kind(exception)
        return unless defined?(::PG::Error) && exception.is_a?(::PG::Error)
        return connection_kind(exception.message) if exception.is_a?(::PG::ConnectionBad)

        FAILURE_KINDS.find { |name, _kind| exception.is_a?(::PG.const_get(name)) }&.last
      end

      # Returns [Module] the kind of failure that the message of `PG::ConnectionBad` means, by the last attempt to connect
      # that it reports, see ATTEMPT and CONNECTION_KINDS, rather than an earlier one, so that an address that refused
      # the connection does not make a database that does not exist on the next one `Unavailable`. A message without
      # the start of an attempt, such as for a connection that was lost, is one attempt.
      def self.connection_kind(message)
        attempt = message.split(ATTEMPT).last || message
        CONNECTION_KINDS.find { |_kind, pattern| pattern.match?(attempt) }&.first
      end
      private_class_method :connection_kind

      # Parameters:
      #   connection: [ActiveRecord::ConnectionAdapters::PostgreSQLAdapter]
      #     The connection that the query is read on, which the caller holds while it is read.
      def initialize(connection)
        @connection = connection
        @name       = "iostreams_cursor_#{object_id}"
        @rows       = []
        @done       = false
        @size       = FIRST_FETCH
      end

      # Yields [IOStreams::Query::PostgresqlCursor] itself, whose #each yields the rows, once the cursor of the query is
      # open: declared, within a transaction, see above, with the SQL and binds that Active Record runs for the query, see
      # `IOStreams::Query::Statement`, its first rows fetched, and the names of its columns checked against those that
      # the query was described by, see `IOStreams::Query::Columns#check`, so that a query that fails, or cannot start,
      # raises before the block is called.
      #
      # The cursor is closed, and the settings set back, once the block finishes, or is left with `break`, which raises a
      # failure to do so, such as of a connection that was lost, rather than return as if the read had ended where the
      # block left it, as `IOStreams::Utils.finish_or_abort` decides, see #restore. When the block, or a fetch, raises
      # instead, or the thread is interrupted, such as by `Timeout`, neither is done: Active Record rolls back the
      # transaction, which ends the cursor and the settings, and first cancels a fetch that is still running, which a
      # statement of the cursor would wait for, and then fail in a transaction that the failure aborted. An
      # `ActiveRecord::Rollback` that the block raises, for a transaction of the caller, is raised again once the
      # transaction of the cursor has rolled back, rather than rescued by it, as Active Record rescues it in any
      # transaction, so that it reaches the transaction of the caller, or the caller, as it does when the block runs
      # anywhere else.
      #
      # Returns the result of the block.
      def open(statement, columns)
        joined   = @connection.transaction_open?
        rollback = nil
        result   = @connection.transaction(requires_new: true) do
          previous = joined ? current_settings : nil
          apply_settings(settings)
          declare(statement)
          fetch(columns)
          Utils.finish_or_abort(finish: -> { restore(previous) }) { yield self }
        rescue ::ActiveRecord::Rollback => e
          rollback = e
          raise
        end
        raise rollback if rollback

        result
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

      # Fetches the next rows of the cursor, whose rows #each yields: FIRST_FETCH rows the first time, then as many as
      # the rows of the last fetch say, see #next_size. It checks the names of the columns of the result of the first
      # fetch against the supplied columns, see `IOStreams::Query::Columns#check`. Once a fetch returns fewer rows than
      # it asked for, there are none left to fetch.
      def fetch(columns = nil)
        size   = @size
        result = uncached { @connection.select_all("FETCH FORWARD #{size} FROM #{@name}", "IOStreams Fetch") }
        columns&.check(result.columns)
        @rows = result.rows
        @done = @rows.size < size
        @size = next_size(@rows) unless @done
      end

      # Returns [Integer] the number of rows of the next fetch: as many as hold about FETCH_BYTES of raw values, by the
      # size of the first FIRST_FETCH of the supplied rows, of the last fetch, so that a fetch holds about as much memory
      # however wide the rows are, which #each releases as it yields them, but at least one row, and at most MAX_FETCH,
      # so that narrow rows are not fetched in more round trips than they need. A value that is text counts its bytes,
      # and any other value VALUE_BYTES.
      def next_size(rows)
        sample = rows.first(FIRST_FETCH)
        bytes  = sample.sum { |row| row.sum { |value| value.is_a?(String) ? value.bytesize : VALUE_BYTES } }
        (FETCH_BYTES * sample.size / [bytes, 1].max).clamp(1, MAX_FETCH)
      end

      # Closes the cursor, and sets back the settings of the transaction that was already open, once the read finished,
      # which also checks that its transaction was not aborted.
      def restore(previous)
        run("CLOSE #{@name}")
        apply_settings(previous) if previous
      end

      # Returns [Hash<String, String>] the SETTINGS that the version of PostgreSQL of the connection has, see
      # SETTING_VERSIONS, as Active Record answers it, which it asks once for each pool.
      def settings
        version = @connection.database_version
        SETTINGS.select { |name, _value| version >= SETTING_VERSIONS.fetch(name, 0) }
      end

      # Returns [Hash<String, String>] the value of each of the settings in the transaction, see #settings.
      def current_settings
        names  = settings.keys
        values = uncached do
          @connection.select_rows("SELECT #{names.map { |name| "current_setting('#{name}')" }.join(', ')}", "IOStreams")
        end.first
        names.zip(values).to_h
      end

      # Sets each of the supplied settings, of their names and values, for the rest of the transaction.
      def apply_settings(values)
        assignments = values.map do |name, value|
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
