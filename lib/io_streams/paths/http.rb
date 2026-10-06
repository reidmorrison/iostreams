require "net/http"
require "uri"
require "cgi"
module IOStreams
  module Paths
    class HTTP < IOStreams::Path
      attr_reader :username, :password, :http_redirect_count, :url

      # Requests that do not change the file, so that they can follow a redirect to another host.
      SAFE_REQUESTS = [Net::HTTP::Get, Net::HTTP::Head].freeze
      private_constant :SAFE_REQUESTS

      # Stream to/from a remote file over http(s).
      #
      # Reading uses an HTTP GET, and writing uses an HTTP PUT of the entire file.
      # `#exist?` and `#size` use an HTTP HEAD, and `#delete` uses an HTTP DELETE.
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
      #       Supply them with the `username:` and `password:` arguments instead.
      #
      #   parameters: [Hash]
      #     Parameters to add to the query string of the url, for example `{q: "search term"}`.
      #     A parameter replaces any with the same name already in the url.
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
      #     Only applies when reading: writing to a path with a maximum_file_size raises ArgumentError.
      #     Default: nil (no limit).
      #
      #   headers: [Hash]
      #     Optional headers to add to every request, for example
      #     `{"Authorization" => "Bearer token"}`, or `{"Content-Type" => "text/csv"}` when writing.
      #     Since any header may hold a credential, such as `X-Api-Key`, none of them are resent
      #     when a redirect points at a different scheme, host, or port.
      #     Default: nil (no additional headers).
      #
      # Security notes:
      # - Redirect targets are supplied by the remote server. Validating only the url that is
      #   passed in is therefore not sufficient to prevent SSRF: use `allow_hosts` (or disable
      #   redirects with `http_redirect_count: 0`) when the url is not fully trusted.
      # - Basic authentication credentials, and the supplied headers, are only sent to the original
      #   host. They are not resent when a redirect points at a different scheme, host, or port,
      #   so that a redirect cannot leak the credentials to another server.
      # - A redirect from https to http is not followed, so that the data cannot be read or changed in transit.
      # - When writing or deleting, a redirect is only followed to the same scheme, host, and port, so that a
      #   redirect cannot send the data being uploaded to another server, or delete a file on it.
      # - Each redirect that is followed is logged at info level via `IOStreams.logger`.
      def initialize(url, username: nil, password: nil, http_redirect_count: 10, parameters: nil,
                     allow_hosts: nil, maximum_file_size: nil, headers: nil)
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
        @headers             = validate_headers(headers)
        url                  = Utils.root_url(url)
        @url                 = parameters ? add_parameters(url, parameters) : url
        # Decoded like S3 and SFTP paths, so that for example `#basename` is the file name rather than its url form.
        # Unlike a query string, `+` in a path is not a space. A url without a path is the root path `/`.
        path                 = URI.decode_uri_component(uri.path)
        super(path.empty? ? "/" : path)
      end

      # Does not support relative file names since there is no concept of current working directory
      def relative?
        false
      end

      def absolute?
        true
      end

      def to_s
        url
      end

      # HTTP has no directories, so there is nothing to create.
      def mkpath
        self
      end

      def mkdir
        self
      end

      # Returns [true|false] whether the file exists, using an HTTP HEAD.
      #
      # Returns false when the server responds with 404 Not Found or 410 Gone.
      # Raises [IOStreams::Errors::CommunicationsFailure] for any other unsuccessful response, for example when
      # the server does not support HEAD requests.
      def exist?
        authorize!
        send_request(Net::HTTP::Head, url, http_redirect_count, allow_missing: true) { |_response| true } || false
      end

      # Returns [Integer] the size of the file from the Content-Length of an HTTP HEAD, or nil when the file does
      # not exist, or the server does not supply its size.
      def size
        authorize!
        send_request(Net::HTTP::Head, url, http_redirect_count, allow_missing: true, &:content_length)
      end

      # Deletes the file, using an HTTP DELETE.
      #
      # Returns self
      #
      # Notes:
      # * No error is raised when the server responds with 404 Not Found or 410 Gone.
      # * Like writing, only a 307 or 308 redirect to the same scheme, host, and port is followed.
      def delete
        authorize!
        send_request(Net::HTTP::Delete, url, http_redirect_count, allow_missing: true) { |_response| nil }
        self
      end

      protected

      # Returns [String] the url without the user name, password, query or fragment, see #loggable.
      def display_name
        loggable(URI.parse(url))
      end

      # Sets the path, also changing the url to use it, for example when called by `#join` or `#directory`.
      #
      # Each directory or file name that is unchanged keeps its encoding from the url, so that for example the
      # directory of `a%2541/b.csv` is still `a%2541`, rather than `a%41` from encoding its decoded name `a%41`.
      #
      # In a new name, such as from `#join`, characters that cannot appear in a url path, such as a space, `?`
      # or `#`, are percent-encoded in the url. A `%` followed by two hexadecimal digits is assumed to already be
      # percent-encoded, any other `%` is encoded.
      def path=(path)
        super
        uri           = URI.parse(url)
        encoded       = uri.path.split("/", -1)
        uri.path      = self.path.split("/", -1).each_with_index.map do |name, index|
          encoded[index] && URI.decode_uri_component(encoded[index]) == name ? encoded[index] : escape_path(name)
        end.join("/")
        @url          = uri.to_s
        @original_uri = nil
      end

      private

      # Returns [String] the url with the parameters added to its query string.
      #
      # A parameter replaces any with the same name in the url, so that the last value supplied is used,
      # for example to override a setting in a common url. The rest of the url is unchanged.
      def add_parameters(url, parameters)
        return url if parameters.empty?

        url, hash, fragment = url.partition("#")
        url, _, query       = url.partition("?")
        names               = parameters.keys.map(&:to_s)
        kept                = query.split("&").reject do |pair|
          names.include?(URI.decode_www_form_component(pair.split("=", 2).first.to_s))
        end
        "#{url}?#{[*kept, URI.encode_www_form(parameters)].join('&')}#{hash}#{fragment}"
      end

      # Characters that can appear in a url path, besides `%`, which is assumed to already be percent-encoded.
      PATH_CHARACTERS = %r{[A-Za-z0-9\-._~!$&'()*+,;=:@/%]}
      private_constant :PATH_CHARACTERS

      # A `%` that does not start a percent-encoded character.
      UNENCODED_PERCENT = /%(?![0-9A-Fa-f]{2})/
      private_constant :UNENCODED_PERCENT

      def escape_path(path)
        path.gsub(UNENCODED_PERCENT, "%25").
          each_char.map { |char| char.match?(PATH_CHARACTERS) ? char : URI.encode_uri_component(char) }.join
      end

      attr_reader :allow_hosts, :maximum_file_size, :headers

      # Returns [Hash<String, String>] the supplied headers, frozen.
      def validate_headers(headers)
        return {}.freeze if headers.nil?
        raise(ArgumentError, "headers: must be a Hash, not #{headers.class}") unless headers.is_a?(Hash)

        headers.to_h { |name, value| [name.to_s.freeze, value.to_s.freeze] }.freeze
      end

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
        result = nil
        send_request(Net::HTTP::Get, url, http_redirect_count) do |response|
          # Since Net::HTTP download only supports a push stream, write it to a tempfile first.
          Utils.private_temp_file("iostreams_http") do |file_name|
            download_to_file(response, file_name)
            # Return a read stream
            result = ::File.open(file_name, "rb") { |io| builder.reader(io, &block) }
          end
        end
        result
      end

      # Write a file using an http put.
      #
      # For example:
      #   IOStreams.path('https://example.com/upload/file.csv').write("name,age\njack,21\n")
      #
      # Notes:
      # * The data is written to a tempfile first, and then uploaded in a single request once
      #   the block completes, so that the server receives its size in the Content-Length header.
      # * Only a 307 or 308 redirect to the same scheme, host, and port is followed when writing.
      #   The other redirects change the request into a GET, which would discard the upload, and
      #   a redirect to another server would send it the data being uploaded.
      def stream_writer(&block)
        if maximum_file_size
          raise(ArgumentError, "maximum_file_size: only applies when reading from an HTTP path, not when writing")
        end

        Utils.private_temp_file("iostreams_http") do |file_name|
          result = ::File.open(file_name, "wb") { |io| builder.writer(io, &block) }
          send_request(Net::HTTP::Put, url, http_redirect_count, body_file_name: file_name) { |_response| nil }
          result
        end
      end

      # Skips the HTTP HEAD before a copy to this path, and the HTTP DELETE after a failed one.
      #
      # An upload is a single request with its Content-Length, so a server can discard a truncated upload
      # instead of keeping an incomplete file. A url can also be limited to an upload, such as a pre-signed
      # url, where a HEAD or DELETE request fails, so that a copy to it would always fail.
      def existed_before_copy?
        true
      end

      # Sends the request, following redirects, and returns the result of the block, which is called
      # with the successful response.
      #
      # When a body_file_name is supplied its contents are sent as the body of the request.
      # When allow_missing is true, returns nil without calling the block when the server responds with
      # 404 Not Found or 410 Gone.
      def send_request(request_class, uri, http_redirect_count, body_file_name: nil, allow_missing: false, &block)
        uri    = URI.parse(uri) unless uri.is_a?(URI)
        result = nil

        validate_uri!(uri)

        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          request = build_request(request_class, uri)
          # So that the Content-Length is the size of the file, not of a compressed response.
          request["Accept-Encoding"] = "identity" if request_class == Net::HTTP::Head
          body = body_file_name ? ::File.open(body_file_name, "rb") : nil
          if body
            request.body_stream    = body
            request.content_length = body.size
            request.content_type   = "application/octet-stream" unless request["content-type"]
          end

          begin
            http.request(request) do |response|
              return nil if allow_missing && (response.is_a?(Net::HTTPNotFound) || response.is_a?(Net::HTTPGone))

              if response.is_a?(Net::HTTPNotFound)
                raise(IOStreams::Errors::CommunicationsFailure, "Invalid URL: #{without_credentials(uri)}")
              end
              if response.is_a?(Net::HTTPUnauthorized)
                raise(IOStreams::Errors::CommunicationsFailure, "Authorization Required: Invalid :username or :password.")
              end

              if response.is_a?(Net::HTTPRedirection)
                new_uri = redirect_uri(uri, response, http_redirect_count, request_class)
                return send_request(
                  request_class, new_uri, http_redirect_count - 1,
                  body_file_name: body_file_name, allow_missing: allow_missing, &block
                )
              end

              unless response.is_a?(Net::HTTPSuccess)
                raise(IOStreams::Errors::CommunicationsFailure, "Invalid response code: #{response.code}")
              end

              result = block.call(response)
            end
          ensure
            body&.close
          end
        end
        result
      end

      # Returns [Net::HTTPRequest] the request, with the supplied headers and credentials
      # when it is sent to the original host.
      def build_request(request_class, uri)
        request = request_class.new(uri)
        # Only send headers and credentials to the original host to avoid leaking them via a redirect.
        if same_origin?(uri)
          headers.each { |name, value| request[name] = value }
          request.basic_auth(username, password) if username
        end
        request
      end

      # Returns [URI] the location to redirect to, resolved against the current uri.
      def redirect_uri(uri, response, http_redirect_count, request_class)
        raise(IOStreams::Errors::CommunicationsFailure, "Too many redirects") if http_redirect_count < 1

        # Other redirects change the request into a GET, which would discard the body being sent.
        if !SAFE_REQUESTS.include?(request_class) && !%w[307 308].include?(response.code)
          raise(
            IOStreams::Errors::CommunicationsFailure,
            "Only a 307 or 308 redirect can be followed when writing or deleting, " \
            "received #{response.code}: #{without_credentials(uri)}"
          )
        end

        location = response["location"]
        unless location
          raise(IOStreams::Errors::CommunicationsFailure,
                "Redirect missing location header: #{without_credentials(uri)}")
        end

        # Resolve relative redirects against the current uri.
        new_uri = uri.merge(location)

        if uri.scheme == "https" && new_uri.scheme == "http"
          raise(
            IOStreams::Errors::CommunicationsFailure,
            "Redirect from https to http is not followed: #{without_credentials(uri)} to #{without_credentials(new_uri)}"
          )
        end

        # A redirect to another server would send it the data being uploaded, or delete a file on it.
        if !SAFE_REQUESTS.include?(request_class) && !same_origin?(new_uri)
          raise(
            IOStreams::Errors::CommunicationsFailure,
            "Only a redirect to the same scheme, host and port can be followed when writing or deleting: " \
            "#{without_credentials(uri)} to #{without_credentials(new_uri)}"
          )
        end

        IOStreams.logger&.info("Following HTTP #{response.code} redirect from #{loggable(uri)} to #{loggable(new_uri)}")
        new_uri
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

      # Returns [String] the uri without any user name, password, query or fragment, for logging.
      # The query is removed since it can hold credentials, such as the signature of a pre-signed url.
      def loggable(uri)
        uri          = uri.dup
        uri.user     = nil
        uri.query    = nil
        uri.fragment = nil
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
