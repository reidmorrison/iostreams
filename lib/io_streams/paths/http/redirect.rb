# frozen_string_literal: true

module IOStreams
  module Paths
    class HTTP < IOStreams::Path
      # Decides which redirects the requests of a url follow, and where to, see `IOStreams::Paths::HTTP#send_request`:
      # https is never redirected to http, and a request that changes the file, such as a PUT or a DELETE, only follows
      # a 307 or 308 redirect to the scheme, host and port of the url, since any other redirect would turn it into a GET,
      # or send its data to, or delete a file on, another server.
      class Redirect
        # Requests that do not change the file, so that they can follow a redirect to another host.
        SAFE_REQUESTS = [Net::HTTP::Get, Net::HTTP::Head].freeze

        # Parameters:
        #   original_uri: [URI]
        #     The url of the path, whose scheme, host and port are the only ones that a request that changes the file
        #     follows a redirect to, and the only ones that the credentials and headers of the path are sent to.
        #
        #   loggable: [#call]
        #     Returns the text of a url for a message, without its credentials or query, see
        #     `IOStreams::Paths::HTTP#loggable`.
        def initialize(original_uri, loggable)
          @original_uri = original_uri
          @loggable     = loggable
        end

        # Returns [true|false] whether the uri has the scheme, host and port of the url of the path.
        def same_origin?(uri)
          uri.scheme == @original_uri.scheme && uri.hostname == @original_uri.hostname && uri.port == @original_uri.port
        end

        # Returns [URI] the location that a request of the supplied class follows the redirect response to, resolved
        # against the uri that the request was sent to.
        #
        # Raises [IOStreams::Errors::CommunicationsFailure] when no more redirects are allowed, `http_redirect_count`
        # being the number of them that are left, or when the redirect is not followed.
        def follow(uri, response, http_redirect_count, request_class)
          raise(IOStreams::Errors::CommunicationsFailure, "Too many redirects") if http_redirect_count < 1

          # Other redirects change the request into a GET, which would discard the body being sent.
          if !SAFE_REQUESTS.include?(request_class) && !%w[307 308].include?(response.code)
            raise(
              IOStreams::Errors::CommunicationsFailure,
              "Only a 307 or 308 redirect can be followed when writing or deleting, " \
              "received #{response.code}: #{loggable(uri)}"
            )
          end

          location = response["location"]
          unless location
            raise(IOStreams::Errors::CommunicationsFailure,
                  "Redirect missing location header: #{loggable(uri)}")
          end

          # Resolve relative redirects against the current uri.
          new_uri = resolve(uri, location)

          if uri.scheme == "https" && new_uri.scheme == "http"
            raise(
              IOStreams::Errors::CommunicationsFailure,
              "Redirect from https to http is not followed: #{loggable(uri)} to #{loggable(new_uri)}"
            )
          end

          # A redirect to another server would send it the data being uploaded, or delete a file on it.
          if !SAFE_REQUESTS.include?(request_class) && !same_origin?(new_uri)
            raise(
              IOStreams::Errors::CommunicationsFailure,
              "Only a redirect to the same scheme, host and port can be followed when writing or deleting: " \
              "#{loggable(uri)} to #{loggable(new_uri)}"
            )
          end

          IOStreams.logger&.info("Following HTTP #{response.code} redirect from #{loggable(uri)} to #{loggable(new_uri)}")
          new_uri
        end

        private

        # Returns [URI] the location of a redirect, resolved against the url that redirected.
        #
        # Raises [IOStreams::Errors::CommunicationsFailure] when the location is not a url, without the location in its
        # message, which the server supplies, and which can hold a token, unlike the message of `URI::InvalidURIError`.
        def resolve(uri, location)
          uri.merge(location)
        rescue URI::Error
          raise(IOStreams::Errors::CommunicationsFailure, "Redirect to a location that is not a url: #{loggable(uri)}",
                cause: nil)
        end

        def loggable(uri)
          @loggable.call(uri)
        end
      end
    end
  end
end
