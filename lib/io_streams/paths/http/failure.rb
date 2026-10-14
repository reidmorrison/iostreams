# frozen_string_literal: true

module IOStreams
  module Paths
    class HTTP < IOStreams::Path
      # The kind of failure, such as `IOStreams::Errors::NotFound`, that an unsuccessful response, or an exception
      # raised by a request, means, see `IOStreams::Errors::StorageError`.
      module Failure
        # The kind of failure that each unsuccessful response means.
        RESPONSE_KINDS = {
          Net::HTTPNotFound                    => Errors::NotFound,
          Net::HTTPGone                        => Errors::NotFound,
          Net::HTTPUnauthorized                => Errors::PermissionDenied,
          Net::HTTPForbidden                   => Errors::PermissionDenied,
          Net::HTTPProxyAuthenticationRequired => Errors::PermissionDenied,
          Net::HTTPRequestTimeout              => Errors::Unavailable,
          Net::HTTPTooManyRequests             => Errors::Unavailable,
          Net::HTTPInternalServerError         => Errors::Unavailable,
          Net::HTTPBadGateway                  => Errors::Unavailable,
          Net::HTTPServiceUnavailable          => Errors::Unavailable,
          Net::HTTPGatewayTimeout              => Errors::Unavailable
        }.freeze

        # The exceptions that a request raises when the server cannot be reached, or the connection to it fails.
        NETWORK_ERRORS = [
          EOFError, SocketError, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNABORTED,
          Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EPIPE, Errno::ETIMEDOUT
        ].freeze

        # Returns [Module] the kind of failure that an exception raised by a request means, or nil when it is none of
        # them.
        #
        # A host that does not resolve is not unavailable, since the same request cannot succeed later.
        def self.kind(exception)
          return if Utils.unknown_host?(exception)

          Errors::Unavailable if NETWORK_ERRORS.any? { |error_class| exception.is_a?(error_class) }
        end

        # Returns [Module] the kind of failure that the unsuccessful response means, or nil when it is none of them.
        def self.response_kind(response)
          RESPONSE_KINDS.find { |response_class, _kind| response.is_a?(response_class) }&.last
        end
      end
    end
  end
end
