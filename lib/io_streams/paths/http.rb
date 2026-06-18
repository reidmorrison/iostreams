require "net/http"
require "uri"
require "cgi"
module IOStreams
  module Paths
    class HTTP < IOStreams::Path
      attr_reader :username, :password, :http_redirect_count, :url

      # Stream to/from a remote file over http(s).
      #
      # Parameters:
      #   url: [String]
      #      URI of the file to download.
      #     Example:
      #       https://www5.fdic.gov/idasp/Offices2.zip
      #       http://hostname/path/file_name
      #
      #     Full url showing all the optional elements that can be set via the url:
      #       https://username:password@hostname/path/file_name
      #
      #   username: [String]
      #     When supplied, basic authentication is used with the username and password.
      #
      #   password: [String]
      #     Password to use use with basic authentication when the username is supplied.
      #
      #   http_redirect_count: [Integer]
      #     Maximum number of http redirects to follow.
      #     Set to 0 to disable following redirects entirely.
      #     Default: 10
      #
      #   allow_hosts: [String | Array<String>]
      #     Optional allow-list of host names that may be contacted, applied to the
      #     supplied url and to every redirect that is followed.
      #     When supplied, a request to any other host raises CommunicationsFailure.
      #     Use this to limit Server Side Request Forgery (SSRF) exposure when the url
      #     can be influenced by untrusted input.
      #     Default: nil (any host is allowed).
      #
      #   maximum_file_size: [Integer]
      #     Optional maximum number of bytes to download.
      #     When the response body exceeds this size the download is aborted with a
      #     CommunicationsFailure, protecting against unbounded (denial of service) responses.
      #     Default: nil (no limit).
      #
      # Security notes:
      # - Redirect targets are supplied by the remote server. Validating only the url that is
      #   passed in is therefore not sufficient to prevent SSRF: use `allow_hosts` (or disable
      #   redirects with `http_redirect_count: 0`) when the url is not fully trusted.
      # - Basic authentication credentials are only sent to the original host. They are not
      #   resent when a redirect points at a different scheme, host, or port, so that a
      #   redirect cannot leak the credentials to another server.
      def initialize(url, username: nil, password: nil, http_redirect_count: 10, parameters: nil,
                     allow_hosts: nil, maximum_file_size: nil)
        uri = URI.parse(url)
        unless %w[http https].include?(uri.scheme)
          raise(
            ArgumentError,
            "Invalid URL. Required Format: 'http://<host_name>/<file_name>', or 'https://<host_name>/<file_name>'"
          )
        end

        @username            = username || uri.user
        @password            = password || uri.password
        @http_redirect_count = http_redirect_count
        @allow_hosts         = allow_hosts.nil? ? nil : Array(allow_hosts)
        @maximum_file_size   = maximum_file_size
        @url                 = parameters ? "#{url}?#{URI.encode_www_form(parameters)}" : url
        super(uri.path)
      end

      # Does not support relative file names since there is no concept of current working directory
      def relative?
        false
      end

      def to_s
        url
      end

      private

      attr_reader :allow_hosts, :maximum_file_size

      # Read a file using an http get.
      #
      # For example:
      #   IOStreams.path('https://www5.fdic.gov/idasp/Offices2.zip').reader {|file| puts file.read}
      #
      # Read the file without unzipping and streaming the first file in the zip:
      #   IOStreams.path('https://www5.fdic.gov/idasp/Offices2.zip').stream(:none).reader {|file| puts file.read}
      #
      # Notes:
      # * Since Net::HTTP download only supports a push stream, the data is streamed into a tempfile first.
      def stream_reader(&block)
        handle_redirects(url, http_redirect_count, &block)
      end

      def handle_redirects(uri, http_redirect_count, &block)
        uri    = URI.parse(uri) unless uri.is_a?(URI)
        result = nil

        validate_uri!(uri)

        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          request = Net::HTTP::Get.new(uri)
          # Only send credentials to the original host to avoid leaking them via a redirect.
          request.basic_auth(username, password) if username && same_origin?(uri)

          http.request(request) do |response|
            raise(IOStreams::Errors::CommunicationsFailure, "Invalid URL: #{uri}") if response.is_a?(Net::HTTPNotFound)
            if response.is_a?(Net::HTTPUnauthorized)
              raise(IOStreams::Errors::CommunicationsFailure, "Authorization Required: Invalid :username or :password.")
            end

            if response.is_a?(Net::HTTPRedirection)
              raise(IOStreams::Errors::CommunicationsFailure, "Too many redirects") if http_redirect_count < 1

              location = response["location"]
              raise(IOStreams::Errors::CommunicationsFailure, "Redirect missing location header: #{uri}") unless location

              # Resolve relative redirects against the current uri.
              new_uri = uri.merge(location)
              return handle_redirects(new_uri, http_redirect_count - 1, &block)
            end

            unless response.is_a?(Net::HTTPSuccess)
              raise(IOStreams::Errors::CommunicationsFailure, "Invalid response code: #{response.code}")
            end

            # Since Net::HTTP download only supports a push stream, write it to a tempfile first.
            Utils.temp_file_name("iostreams_http") do |file_name|
              download_to_file(response, file_name)
              # Return a read stream
              result = ::File.open(file_name, "rb") { |io| builder.reader(io, &block) }
            end
          end
        end
        result
      end

      # Validate that the host may be contacted, and that the scheme is still http(s)
      # after following a redirect.
      def validate_uri!(uri)
        unless %w[http https].include?(uri.scheme)
          raise(IOStreams::Errors::CommunicationsFailure, "Invalid redirect, only http and https are supported: #{uri}")
        end
        return if allow_hosts.nil? || allow_hosts.include?(uri.hostname)

        raise(IOStreams::Errors::CommunicationsFailure, "Host not in the allowed list of hosts: #{uri.hostname}")
      end

      def same_origin?(uri)
        original = original_uri
        uri.scheme == original.scheme && uri.hostname == original.hostname && uri.port == original.port
      end

      def original_uri
        @original_uri ||= URI.parse(url)
      end

      def download_to_file(response, file_name)
        size = 0
        ::File.open(file_name, "wb") do |io|
          response.read_body do |chunk|
            size += chunk.bytesize
            if maximum_file_size && (size > maximum_file_size)
              raise(
                IOStreams::Errors::CommunicationsFailure,
                "Exceeded maximum allowed download size of #{maximum_file_size} bytes"
              )
            end
            io.write(chunk)
          end
        end
      end
    end
  end
end
