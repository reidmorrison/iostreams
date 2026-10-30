require "net/http"
require "uri"
require "cgi"
module IOStreams
  module Paths
    class HTTP < IOStreams::Path
      attr_reader :username, :password, :http_redirect_count, :url

      # The password, and the query `parameters`, which can hold an access key, see IOStreams::Path.redact_options.
      def self.sensitive_option_names = %i[password parameters]

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
      #     SECURITY WARNING:
      #       A username and password supplied in the url remain part of it, so `#to_s` and `#url`
      #       return them, as does any log or error message that includes the path.
      #       Supply them with the `username:` and `password:` arguments instead,
      #       and log `#display_name`, which never includes them.
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
        warn_url_without_host(uri)
      end

      # Does not support relative file names since there is no concept of current working directory
      def relative?
        false
      end

      def to_s
        url
      end

      # Returns [String] the url without the user name, password, query or fragment, which can hold credentials,
      # such as the signature of a pre-signed url, or the `parameters:` supplied to this path.
      def display_name
        uri          = URI.parse(url)
        uri.user     = nil
        uri.query    = nil
        uri.fragment = nil
        uri.to_s
      end

      private

      attr_reader :allow_hosts, :maximum_file_size

      # Reports a deprecation warning for a url without a host, such as `http:///a.csv`, which IOStreams 3.0 raises
      # ArgumentError for when the path is created, so that a mistake in a configured url is reported wherever the
      # code runs.
      def warn_url_without_host(uri)
        return unless uri.host.to_s.empty?

        Deprecation.warn("the HTTP url #{display_name.inspect} is deprecated, since it names no host, name one, such " \
                         "as 'https://example.org/a.csv'")
      end

      # The methods of the IO that v3.0 reads the response from, see #v3_source: those of an IO that read, and #close.
      V3_SOURCE_METHODS = [*IOStreams::Reader::V3_READ_METHODS, :close].freeze
      private_constant :V3_SOURCE_METHODS

      # Returns [Array(Array<Symbol>, String)] the methods of the IO that v3.0 reads the response from, in place of the
      # temp File that v2.2 downloads it into, and its name, see `IOStreams::Stream#v3_source`: v3.0 reads the response as
      # the application reads it, with an IO that only reads.
      def v3_source
        [V3_SOURCE_METHODS, "the IO of an HTTP path"]
      end

      # Read a file using an http get.
      #
      # For example:
      #   IOStreams.path('https://www5.fdic.gov/idasp/Offices2.zip').reader {|file| puts file.read}
      #
      # Read the file without unzipping and streaming the first file in the zip:
      #   IOStreams.path('https://www5.fdic.gov/idasp/Offices2.zip').raw.reader {|file| puts file.read}
      #
      # Notes:
      # * Since Net::HTTP download only supports a push stream, the data is streamed into a tempfile first.
      def stream_reader(&)
        handle_redirects(url, http_redirect_count, &)
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
            if response.is_a?(Net::HTTPNotFound)
              raise(IOStreams::Errors::CommunicationsFailure, "Invalid URL: #{without_credentials(uri)}")
            end
            if response.is_a?(Net::HTTPUnauthorized)
              raise(IOStreams::Errors::CommunicationsFailure, "Authorization Required: Invalid :username or :password.")
            end

            if response.is_a?(Net::HTTPRedirection)
              raise(IOStreams::Errors::CommunicationsFailure, "Too many redirects") if http_redirect_count < 1

              location = response["location"]
              unless location
                raise(IOStreams::Errors::CommunicationsFailure,
                      "Redirect missing location header: #{without_credentials(uri)}")
              end

              # Resolve relative redirects against the current uri.
              new_uri = uri.merge(location)
              return handle_redirects(new_uri, http_redirect_count - 1, &block)
            end

            unless response.is_a?(Net::HTTPSuccess)
              raise(IOStreams::Errors::CommunicationsFailure, "Invalid response code: #{response.code}")
            end

            # Since Net::HTTP download only supports a push stream, write it to a tempfile first.
            Utils.private_temp_file("iostreams_http") do |file_name|
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
      #
      # A redirect must also be within the allowed paths, see `IOStreams.add_allowed_path`.
      def validate_uri!(uri)
        unless %w[http https].include?(uri.scheme)
          raise(IOStreams::Errors::CommunicationsFailure,
                "Invalid redirect, only http and https are supported: #{without_credentials(uri)}")
        end
        authorize_location!(http_location(uri)) unless IOStreams.allowed_paths.empty?
        return if allow_hosts.nil? || allow_hosts.include?(uri.hostname)

        raise(IOStreams::Errors::CommunicationsFailure, "Host not in the allowed list of hosts: #{uri.hostname}")
      end

      # Returns [String] the scheme, host, port and path of the url, which is compared against the allowed paths.
      def allowed_location
        http_location(original_uri)
      end

      # Returns [String] the scheme, host, port and path of the supplied uri, without any credentials or query.
      #
      # The path is decoded and `.` and `..` resolved, the way most web servers resolve them, so that for
      # example `%2e%2e` cannot be used to leave an allowed path. A backslash is treated as a `/`.
      def http_location(uri)
        raise(Errors::AccessDenied, "Access denied: #{without_credentials(uri)} has no host") if uri.host.to_s.empty?

        path = URI.decode_uri_component(uri.path).tr("\\", "/")
        "#{uri.scheme}://#{uri.host.downcase}:#{uri.port}#{normalize_path(path)}".chomp("/")
      rescue ArgumentError => e
        raise(Errors::AccessDenied, "Access denied to #{without_credentials(uri)}: #{e.message}")
      end

      # Returns [String] the uri without any user name or password, for use in error messages.
      def without_credentials(uri)
        return uri.to_s unless uri.user

        uri      = uri.dup
        uri.user = nil
        uri.to_s
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
