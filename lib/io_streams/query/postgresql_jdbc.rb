# frozen_string_literal: true

module IOStreams
  class Query
    # Reads the rows of a query on PostgreSQL with a cursor, as `IOStreams::Query::PostgresqlCursor` does, through the
    # PostgreSQL adapter of AR-JDBC, on JRuby, which cannot load the pg gem, a C extension. It knows what differs with
    # PgJDBC, the driver of the adapter: the failures that it raises, see .failure_kind, and the values that it returns,
    # see .requirable_types.
    class PostgresqlJdbc < PostgresqlCursor
      # The kind of failure of each SQLSTATE of PgJDBC, which raises every failure with its SQLSTATE, those of the server,
      # and its own for a connection, see .failure_kind, as FAILURE_KINDS and CONNECTION_KINDS tell apart the failures of
      # the pg gem. Not the `08004` of PgJDBC, connection_rejected, which it raises for a connection that its
      # configuration does not let it make, such as one that requires TLS of a server without it, or an authentication
      # that it does not support, which a retry does not change.
      STATE_KINDS = {
        "08001" => Errors::Unavailable,      # connection_unable_to_connect: refused, timed out, or unreachable
        "08003" => Errors::Unavailable,      # connection_does_not_exist: closed
        "08006" => Errors::Unavailable,      # connection_failure: lost, such as while the rows are read
        "25P03" => Errors::Unavailable,      # idle_in_transaction_session_timeout: a session that the server ended
        "28000" => Errors::PermissionDenied, # invalid_authorization_specification: a role or host that may not connect
        "28P01" => Errors::PermissionDenied, # invalid_password
        "42501" => Errors::PermissionDenied, # insufficient_privilege: a table, column or database that it may not read
        "53300" => Errors::Unavailable,      # too_many_connections
        "57P01" => Errors::Unavailable,      # admin_shutdown
        "57P02" => Errors::Unavailable,      # crash_shutdown
        "57P03" => Errors::Unavailable,      # cannot_connect_now: starting up, shutting down, or in recovery
        "3D000" => Failure::NONE             # invalid_catalog_name: a database that does not exist
      }.freeze

      # The types of field whose columns that are `NOT NULL` always have a value once Active Record casts it, see
      # .requirable_types.
      REQUIRABLE_TYPES = (PostgresqlCursor::REQUIRABLE_TYPES - ["duration"]).freeze

      # Returns [true|false] whether the connection is to PostgreSQL, through an adapter of ADAPTERS, that of AR-JDBC, see
      # `IOStreams::Query::Jdbc.adapter?`.
      def self.reads?(connection)
        ADAPTERS.include?(connection.adapter_name) && Jdbc.adapter?(connection)
      end

      # Returns [Module] the kind of failure that an exception of PgJDBC means: as the exceptions of Java that caused it
      # say, see `IOStreams::Query::Jdbc.cause_kind`, such as a host that does not resolve, or a certificate that is not
      # trusted, which it raises with the SQLSTATE of a connection that could not be made, otherwise by its SQLSTATE, see
      # STATE_KINDS. Returns nil when it is none of them, or another driver raised it.
      def self.failure_kind(exception)
        failure = Jdbc.driver_exception(exception, "org.postgresql.")
        return unless failure

        kind = Jdbc.cause_kind(failure)
        return kind if kind

        STATE_KINDS[failure.sql_state] if failure.is_a?(::Java::JavaSql::SQLException)
      end

      # Returns [Array<String>] the types of field whose columns that are `NOT NULL` always have a value once Active Record
      # casts it, see `IOStreams::Query::Columns`: those of `IOStreams::Query::PostgresqlCursor.requirable_types`, but
      # not an interval, which AR-JDBC returns as text that Active Record casts to nil, when it is zero, or infinite, or
      # has less than a millisecond of seconds, see https://github.com/jruby/activerecord-jdbc-adapter/issues/1230.
      def self.requirable_types
        REQUIRABLE_TYPES
      end

      # Returns [String] the type of field of a column of a type that Active Record does not know, see
      # `IOStreams::Query::Columns`: "any", since AR-JDBC returns the value that it casts, such as a Time for a `timetz`,
      # rather than its text, see https://github.com/jruby/activerecord-jdbc-adapter/issues/1231.
      def self.unknown_type
        "any"
      end
    end
  end
end
