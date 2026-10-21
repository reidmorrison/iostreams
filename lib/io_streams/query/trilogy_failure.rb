# frozen_string_literal: true

module IOStreams
  class Query
    # Returns the kind of failure, such as `IOStreams::Errors::Unavailable`, of an exception of the trilogy gem, the
    # default driver of MySQL of Rails, whose queries are read in batches, since it returns every row of a query at
    # once, so that no source reads with it, see `IOStreams::Query::DRIVER_FAILURES`.
    module TrilogyFailure
      # Returns [Module] the kind of failure that an exception raised by the trilogy gem means, or nil when it is none
      # of them: as MySQL says of the error number that the server sent, see `IOStreams::Query::MysqlFailure`, and
      # `Unavailable` for a timeout, a connection that the server closed, or a server that cannot be reached, or
      # `IOStreams::Query::Failure::NONE` for a host that does not resolve, see .socket_kind.
      def self.failure_kind(exception)
        return unless defined?(::Trilogy::Error) && exception.is_a?(::Trilogy::Error)
        return MysqlFailure.kind(exception.error_code, exception.message) if exception.error_code
        return Errors::Unavailable if exception.is_a?(::Trilogy::TimeoutError) || exception.is_a?(::Trilogy::EOFError)

        socket_kind(exception.cause.is_a?(::SocketError) ? exception.cause : exception)
      end

      # Returns [Module] the kind of failure of the socket that trilogy connects with: `Unavailable` for a server that
      # cannot be reached, see `IOStreams::Errors::Unavailable.network_error?`, or `IOStreams::Query::Failure::NONE` for a
      # host that does not resolve, see `IOStreams::Errors::Unavailable.unknown_host?`. trilogy raises the `SocketError`
      # of a host that does not resolve as the cause of a `Trilogy::BaseConnectionError` of its own, which Active Record
      # raises as an `ActiveRecord::ConnectionNotEstablished` that does not name the host, which is otherwise Unavailable.
      def self.socket_kind(exception)
        return Failure::NONE if Errors::Unavailable.unknown_host?(exception)

        Errors::Unavailable if Errors::Unavailable.network_error?(exception)
      end
      private_class_method :socket_kind
    end
  end
end
