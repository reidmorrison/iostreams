# frozen_string_literal: true

module IOStreams
  class Query
    # Returns the kind of failure, such as `IOStreams::Errors::Unavailable`, for a failure of Active Record to read a
    # query, see `IOStreams::Errors::StorageError`, whatever the database. The source that reads the query on a database
    # knows the failures of its driver, such as `IOStreams::Query::SqliteStatement.failure_kind`.
    module Failure
      # The message of `ActiveRecord::DatabaseConnectionError` for a user name or password that the database rejects,
      # see `ActiveRecord::DatabaseConnectionError.username_error`, rather than a host that it cannot connect to.
      CREDENTIALS = %r{username/password}

      # The message of `ActiveRecord::ConnectionNotEstablished` for a role or shard without a database, before Active
      # Record 8.0 raised `ActiveRecord::ConnectionNotDefined` for it.
      NO_POOL = /\ANo connection pool for /

      # Returns [Module] the kind of failure that an exception raised while reading a query means, or nil when it is none
      # of them. For an exception of Active Record:
      #   `Unavailable`: a connection that could not be made, or was lost, no connection free in the pool, or a query
      #   that the database canceled or timed out, or rolled back for a lock or a deadlock, so that it can succeed later.
      #   `PermissionDenied`: a user name or password that the database rejects.
      # A role or shard without a database is a mistake of configuration, so it is neither.
      #
      # Yields the exception of the driver of the database, for the kind of failure that it means, which the source of
      # that database knows: one that the driver raised itself, such as while a source streams its rows, the cause of an
      # `ActiveRecord::StatementInvalid`, such as a table that the user may not read, or `ActiveRecord::NoDatabaseError`,
      # which Active Record raises for a message that names the database, and the cause of a connection that
      # could not be made, since Active Record names it by its message, which names the host for a connection that the
      # server refused, as well as for a host that does not resolve, which is not `Unavailable`, as for a path, see
      # `IOStreams::Errors::Unavailable.unknown_host?`.
      def self.kind(exception, &)
        unless defined?(::ActiveRecord::ActiveRecordError) && exception.is_a?(::ActiveRecord::ActiveRecordError)
          return yield(exception)
        end

        case exception
        when ::ActiveRecord::ConnectionNotEstablished
          connection_kind(exception, &)
        when ::ActiveRecord::QueryAborted, ::ActiveRecord::LockWaitTimeout, ::ActiveRecord::TransactionRollbackError
          Errors::Unavailable
        when ::ActiveRecord::StatementInvalid
          yield(exception.cause) if exception.cause
        end
      end

      # Returns [Module] the kind of failure of a connection that could not be made, or was lost: as the driver of the
      # database says of the exception that caused it, otherwise `PermissionDenied` for credentials that Active Record
      # says were rejected, and `Unavailable` for any other, such as a pool without a connection free, apart from an
      # `ActiveRecord::DatabaseConnectionError` that names the host, which can be one that does not resolve, when the
      # driver does not say otherwise.
      def self.connection_kind(exception)
        return if no_pool?(exception)

        kind = exception.cause && yield(exception.cause)
        return kind if kind
        return Errors::PermissionDenied if CREDENTIALS.match?(exception.message)

        Errors::Unavailable unless exception.is_a?(::ActiveRecord::DatabaseConnectionError)
      end

      # Returns [true|false] whether the exception is for a role or shard without a database.
      def self.no_pool?(exception)
        (defined?(::ActiveRecord::ConnectionNotDefined) && exception.is_a?(::ActiveRecord::ConnectionNotDefined)) ||
          NO_POOL.match?(exception.message)
      end
      private_class_method :connection_kind, :no_pool?
    end
  end
end
