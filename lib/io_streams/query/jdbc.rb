# frozen_string_literal: true

module IOStreams
  class Query
    # What IOStreams knows of AR-JDBC, the adapters of Active Record on JRuby, see
    # https://github.com/jruby/activerecord-jdbc-adapter, which the sources that read with it share: whether a
    # connection is through one of them, see .adapter?, and its failures. The driver of each database is a jar, which
    # raises a `java.sql.SQLException`, that AR-JDBC wraps in an `ActiveRecord::JDBCError`, also for a connection that it
    # could not make, rather than raising `ActiveRecord::ConnectionNotEstablished`. The source of each database knows
    # what the exception of its driver means, see the `.failure_kind` of `IOStreams::Query::PostgresqlJdbc`,
    # `IOStreams::Query::MysqlJdbc` and `IOStreams::Query::SqliteJdbc`.
    module Jdbc
      # Returns [true|false] whether the connection is through an adapter of AR-JDBC, which every adapter of it includes
      # `ArJdbc::Abstract::Core` for, without asking for its raw connection, which would mark the connection of the
      # caller as used by the application, so that Active Record would no longer verify or reconnect it.
      def self.adapter?(connection)
        return false unless defined?(::ArJdbc::Abstract::Core)

        connection.is_a?(::ArJdbc::Abstract::Core)
      end

      # Returns [java.sql.SQLException] the exception of the driver of a database that the supplied exception is, or
      # wraps, as AR-JDBC wraps it in an `ActiveRecord::JDBCError`, when the driver is the one of the supplied name, the
      # start of the names of its Java classes, such as "com.mysql.", or nil for any other exception, such as every
      # exception on MRI. A driver can raise a `java.sql.SQLException` itself, rather than a class of its own, so the
      # driver that raised it is told by the class of the exception, or else the class that created it.
      def self.sql_exception(exception, driver)
        return unless defined?(::Java::JavaSql::SQLException)

        if defined?(::ActiveRecord::JDBCError) && exception.is_a?(::ActiveRecord::JDBCError)
          exception = exception.jdbc_exception || exception.cause
        end
        exception if exception.is_a?(::Java::JavaSql::SQLException) && raised_by?(exception, driver)
      end

      # Returns [Module] the kind of failure of a connection that failed since the name of its host does not resolve,
      # which a driver reports with a `java.net.UnknownHostException` among the exceptions that caused it: `Unavailable`
      # when name resolution failed for the time being, such as a DNS outage, see
      # `IOStreams::Errors::Unavailable::TEMPORARY_RESOLUTION_FAILURE`, otherwise `IOStreams::Query::Failure::NONE`,
      # such as a mistyped host, as for a path, see `IOStreams::Errors::Unavailable.unknown_host?`. Returns nil when no
      # such exception caused it.
      def self.unknown_host_kind(exception)
        cause = exception
        while cause
          if cause.is_a?(::Java::JavaNet::UnknownHostException)
            temporary = Errors::Unavailable::TEMPORARY_RESOLUTION_FAILURE.match?(cause.message.to_s)
            return temporary ? Errors::Unavailable : Failure::NONE
          end

          cause = cause.cause
        end
        nil
      end

      # Returns [true|false] whether a failure of input or output, a `java.io.IOException`, caused the supplied exception
      # of a driver, such as a connection that was refused, reset, timed out, or lost while the rows were read, which a
      # driver can raise without a SQLSTATE that says so. A host that does not resolve is one too, so the source of a
      # database asks for it first, see .unknown_host_kind.
      def self.io_failure?(exception)
        cause = exception.cause
        while cause
          return true if cause.is_a?(::Java::JavaIo::IOException)

          cause = cause.cause
        end
        false
      end

      # Returns [true|false] whether the supplied Java exception is one of the classes of the driver of the supplied name,
      # or was created by one of them, as the first frame of its stack trace says.
      def self.raised_by?(exception, driver)
        return true if exception.java_class.name.start_with?(driver)

        frame = exception.stack_trace.first
        frame ? frame.class_name.start_with?(driver) : false
      end
      private_class_method :raised_by?
    end
  end
end
