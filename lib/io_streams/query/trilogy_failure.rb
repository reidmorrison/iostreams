# frozen_string_literal: true

module IOStreams
  class Query
    # Returns the kind of failure, such as `IOStreams::Errors::Unavailable`, of an exception of the trilogy gem, the
    # default driver of MySQL of Rails, whose queries are read in batches, since it returns every row of a query at
    # once, so that no source reads with it, see `IOStreams::Query::DRIVER_FAILURES`.
    module TrilogyFailure
      # Returns [Module] the kind of failure that an exception raised by the trilogy gem means, or nil when it is none
      # of them: as MySQL says of the error number that the server sent, see `IOStreams::Query::MysqlFailure`, and
      # `Unavailable` for a timeout, a connection that the server closed, or a server that cannot be reached, see
      # `IOStreams::Errors::Unavailable.network_error?`.
      def self.failure_kind(exception)
        return unless defined?(::Trilogy::Error) && exception.is_a?(::Trilogy::Error)
        return MysqlFailure.kind(exception.error_code, exception.message) if exception.error_code

        if exception.is_a?(::Trilogy::TimeoutError) || exception.is_a?(::Trilogy::EOFError) ||
           Errors::Unavailable.network_error?(exception)
          Errors::Unavailable
        end
      end
    end
  end
end
