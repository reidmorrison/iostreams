# frozen_string_literal: true

module IOStreams
  class Query
    # What IOStreams knows of AR-JDBC, the adapters of Active Record on JRuby, see
    # https://github.com/jruby/activerecord-jdbc-adapter, which the sources that read with it share: whether a
    # connection is through one of them, see .adapter?, and its failures. The driver of each database is a jar, which
    # raises a `java.sql.SQLException`, that AR-JDBC wraps in an `ActiveRecord::JDBCError`, also for a connection that it
    # could not make, rather than raising `ActiveRecord::ConnectionNotEstablished`, see .driver_exception. What the
    # exceptions of Java that caused it say is the same for every driver, see .cause_kind, and the source of each
    # database knows what the rest of the exception of its driver means, see the `.failure_kind` of
    # `IOStreams::Query::PostgresqlJdbc`, `IOStreams::Query::MysqlJdbc` and `IOStreams::Query::SqliteJdbc`.
    module Jdbc
      # The cause that Ruby records for an exception, which `ActiveRecord::JDBCError#cause` does not return for an
      # exception of Java that AR-JDBC wraps without a `java.sql.SQLException`, see .driver_exception, since it returns
      # the exception that was being rescued when AR-JDBC created it, if any.
      CAUSE = ::Exception.instance_method(:cause)
      private_constant :CAUSE

      # Returns [true|false] whether the connection is through an adapter of AR-JDBC, which every adapter of it includes
      # `ArJdbc::Abstract::Core` for, without asking for its raw connection, which would mark the connection of the
      # caller as used by the application, so that Active Record would no longer verify or reconnect it.
      def self.adapter?(connection)
        return false unless defined?(::ArJdbc::Abstract::Core)

        connection.is_a?(::ArJdbc::Abstract::Core)
      end

      # Returns [java.lang.Throwable] the exception of the driver of a database that the supplied exception is, or that
      # AR-JDBC wraps in an `ActiveRecord::JDBCError`, when the driver is the one of the supplied name, the start of the
      # names of its Java classes, such as "com.mysql.", or nil for any other exception, such as every exception on MRI.
      #
      # AR-JDBC wraps the `java.sql.SQLException` of a driver, see `ActiveRecord::JDBCError#jdbc_exception`. When it
      # retries a statement on a connection that it then cannot make again, it wraps the exception that caused the
      # failure to connect instead, such as a `java.net.ConnectException`, as the cause that Ruby records, see CAUSE,
      # or raises that exception itself when it is not a checked exception of Java, such as
      # `com.mysql.cj.exceptions.CJCommunicationsException`. A driver can raise a
      # `java.sql.SQLException` itself, rather than a class of its own, so the driver that raised an exception is told
      # by its class, or else by the classes that created it, see .raised_by?.
      def self.driver_exception(exception, driver)
        return unless defined?(::Java::JavaLang::Throwable)

        exception = wrapped(exception) if defined?(::ActiveRecord::JDBCError) && exception.is_a?(::ActiveRecord::JDBCError)
        exception if exception.is_a?(::Java::JavaLang::Throwable) && raised_by?(exception, driver)
      end

      # Returns [Module] the kind of failure that the exceptions of Java among the causes of the supplied exception of a
      # driver say, whatever the driver, or nil when they say none, so that the source of the database tells it by the
      # rest of the exception of its driver, such as its SQLSTATE:
      #   A host that does not resolve, a `java.net.UnknownHostException`: `Unavailable` when name resolution failed for
      #   the time being, such as a DNS outage, see `IOStreams::Errors::Unavailable::TEMPORARY_RESOLUTION_FAILURE`,
      #   otherwise `IOStreams::Query::Failure::NONE`, such as a mistyped host, as for a path, see
      #   `IOStreams::Errors::Unavailable.unknown_host?`.
      #   A failure of TLS that a retry does not change, see .lasting_tls_failure?: `IOStreams::Query::Failure::NONE`, as
      #   for those of libpq, see `IOStreams::Query::PostgresqlCursor::CONNECTION_KINDS`.
      #   Any other failure of input or output, a `java.io.IOException`, such as a connection that was refused, reset,
      #   timed out, or lost while the rows were read, which a driver can raise without a SQLSTATE that says so:
      #   `Unavailable`.
      def self.cause_kind(exception)
        causes  = causes(exception)
        unknown = causes.find { |cause| cause.is_a?(::Java::JavaNet::UnknownHostException) }
        return unknown_host_kind(unknown) if unknown
        return Failure::NONE if lasting_tls_failure?(causes)

        Errors::Unavailable if causes.any?(::Java::JavaIo::IOException)
      end

      # Returns [java.lang.Throwable|nil] the exception of Java that AR-JDBC wraps in the supplied
      # `ActiveRecord::JDBCError`, see .driver_exception.
      def self.wrapped(error)
        error.jdbc_exception || CAUSE.bind_call(error)
      end
      private_class_method :wrapped

      # Returns [Array<java.lang.Throwable>] the supplied exception and each one that caused it, in order, once each.
      def self.causes(exception)
        causes = []
        while exception && !causes.include?(exception)
          causes << exception
          exception = exception.cause
        end
        causes
      end
      private_class_method :causes

      # Returns [Module] the kind of failure of the supplied `java.net.UnknownHostException`, see .cause_kind.
      def self.unknown_host_kind(exception)
        temporary = Errors::Unavailable::TEMPORARY_RESOLUTION_FAILURE.match?(exception.message.to_s)
        temporary ? Errors::Unavailable : Failure::NONE
      end
      private_class_method :unknown_host_kind

      # Returns [true|false] whether a failure of TLS, a `javax.net.ssl.SSLException`, is among the supplied exceptions,
      # see .causes, that a retry does not change, such as a certificate that is not trusted, which a
      # `java.security.GeneralSecurityException` caused, or no protocol or cipher in common, rather than a connection that
      # was reset or closed during the handshake, or while the rows were read, which a failure of input or output outside
      # TLS caused.
      def self.lasting_tls_failure?(causes)
        tls = causes.index { |cause| cause.is_a?(::Java::JavaxNetSsl::SSLException) }
        return false unless tls

        causes.drop(tls + 1).none? do |cause|
          cause.is_a?(::Java::JavaIo::IOException) && !cause.is_a?(::Java::JavaxNetSsl::SSLException)
        end
      end
      private_class_method :lasting_tls_failure?

      # Returns [true|false] whether the supplied Java exception is one of the classes of the driver of the supplied
      # name, or one of them created it, as a frame of its stack trace says, such as a `java.net.ConnectException` of a
      # socket that the driver opened.
      def self.raised_by?(exception, driver)
        exception.java_class.name.start_with?(driver) ||
          exception.stack_trace.any? { |frame| frame.class_name.start_with?(driver) }
      end
      private_class_method :raised_by?
    end
  end
end
