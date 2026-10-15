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

        # The exceptions that Net::HTTP raises when the connection to the server fails, besides those of every
        # connection, see `IOStreams::Errors::Unavailable::CONNECTION_ERRORS`.
        CONNECTION_ERRORS = [EOFError, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Errno::EPIPE].freeze

        # Returns [Module] the kind of failure that an exception raised by a request means, or nil when it is none of
        # them, see `IOStreams::Errors::Unavailable.network_error?`.
        def self.kind(exception)
          Errors::Unavailable if Errors::Unavailable.network_error?(exception, also: CONNECTION_ERRORS)
        end

        # Returns [Module] the kind of failure that the unsuccessful response means, or nil when it is none of them.
        def self.response_kind(response)
          RESPONSE_KINDS.find { |response_class, _kind| response.is_a?(response_class) }&.last
        end
      end
    end
  end
end
