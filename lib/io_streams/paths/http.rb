# frozen_string_literal: true

require "net/http"
require "uri"
# For Time.httpdate, see #mtime.
require "time"
module IOStreams
  module Paths
    class HTTP < IOStreams::Path
      autoload :BodyReader, "io_streams/paths/http/body_reader"
      autoload :ContentCoding, "io_streams/paths/http/content_coding"
      autoload :Failure, "io_streams/paths/http/failure"

      attr_reader :username, :password, :http_redirect_count, :url

      # Requests that do not change the file, so that they can follow a redirect to another host.
      SAFE_REQUESTS = [Net::HTTP::Get, Net::HTTP::Head].freeze
      private_constant :SAFE_REQUESTS

      # The password, the query `parameters`, which can hold an access key, and the cookie headers, see
      # IOStreams::Path.redact_options. The authentication headers, such as "Authorization", "Proxy-Authorization",
      # "X-Auth-Token" and "X-Api-Key", are sensitive by name.
      def self.sensitive_option_names = %i[password parameters cookie set_cookie]

      # Stream to/from a remote file over http(s).
      #
      # Reading uses an HTTP GET, and writing uses an HTTP PUT of the entire file.
      # `#exist?` and `#size` use an HTTP HEAD, and `#delete` uses an HTTP DELETE.
      #
      # Parameters:
      #   url: [String]
      #      URI of the file to download.
      #     Example:
      #       https://example.com/files/data.zip
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
      #     supplied url and to every redirect that is followed. Names are compared without case.
      #     When supplied, a request to any other host raises CommunicationsFailure.
      #     Use this to limit Server Side Request Forgery (SSRF) exposure when the url
      #     can be influenced by untrusted input.
      #     Default: nil (any host is allowed).
      #
      #   maximum_file_size: [Integer]
      #     Optional maximum number of bytes to download.
      #     When the response body exceeds this size the download is aborted with a
      #     CommunicationsFailure, protecting against unbounded (denial of service) responses.
      #     A body that the server compressed while it sent it is also limited to this size once
      #     it is decompressed, since a small body can decompress to far more data.
      #     Only applies when reading: writing to a path with a maximum_file_size raises ArgumentError.
      #     Default: nil (no limit).
      #
      #   headers: [Hash]
      #     Optional headers to add to every request, for example
      #     `{"Authorization" => "Bearer token"}`, or `{"Content-Type" => "text/csv"}` when writing.
      #     Since any header may hold a credential, such as `X-Api-Key`, none of them are resent
      #     when a redirect points at a different scheme, host, or port, apart from an `Accept-Encoding`.
      #     An `Accept-Encoding`, such as `{"Accept-Encoding" => "identity"}`, is sent instead of the one
      #     that reading chooses, see #stream_reader, and the body is then read as it is sent.
      #     Default: nil (no additional headers).
      #
      # Security notes:
      # - Redirect targets are supplied by the remote server. Validating only the url that is
      #   passed in is therefore not sufficient to prevent SSRF: use `allow_hosts` (or disable
      #   redirects with `http_redirect_count: 0`) when the url is not fully trusted.
      # - Basic authentication credentials, and the supplied headers, are only sent to the original
      #   host. They are not resent when a redirect points at a different scheme, host, or port,
      #   so that a redirect cannot leak the credentials to another server. A supplied `Accept-Encoding`
      #   is the exception, since it holds no credential, so that the body is still read as it is sent.
      # - A redirect from https to http is not followed, so that the data cannot be read or changed in transit.
      # - When writing or deleting, a redirect is only followed to the same scheme, host, and port, so that a
      #   redirect cannot send the data being uploaded to another server, or delete a file on it.
      # - Each redirect that is followed is logged at info level via `IOStreams.logger`.
      def initialize(url, username: nil, password: nil, http_redirect_count: 10, parameters: nil,
                     allow_hosts: nil, maximum_file_size: nil, headers: nil)
        uri = Utils::URI.parse(url)
        unless %w[http https].include?(uri.scheme)
          raise(
            ArgumentError,
            "Invalid URL. Required Format: 'http://<host_name>/<file_name>', or 'https://<host_name>/<file_name>'"
          )
        end
        if uri.host.to_s.empty?
          raise(Utils::URI.invalid("HTTP", url, "it must name a host, such as 'https://example.org/a.csv'"))
        end

        @username            = username || uri.user
        @password            = password || uri.password
        @http_redirect_count = http_redirect_count
        @allow_hosts         = allow_hosts.nil? ? nil : Array(allow_hosts)
        @maximum_file_size   = maximum_file_size
        # Held in a Hash, like `IOStreams::Paths::S3#client_cache`, so that it is also created when this
        # path is frozen, for example a root path, see `IOStreams::Path#freeze`.
        @original_uri_cache  = {}
        @headers             = validate_headers(headers)
        url                  = Utils::URI.root(url)
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

      # Returns [Integer] the size of the file from the Content-Length of an HTTP HEAD, or nil when the server does not
      # supply its size.
      #
      # Raises [IOStreams::Errors::NotFound] when the server responds with 404 Not Found or 410 Gone, see `#size?`.
      def size
        authorize!
        send_request(Net::HTTP::Head, url, http_redirect_count, &:content_length)
      end

      # Returns [Time] when the file was last modified, from the Last-Modified header of an HTTP HEAD,
      # or nil when the server does not supply it, or supplies a value that is not a time, which is logged.
      def mtime
        authorize!
        send_request(Net::HTTP::Head, url, http_redirect_count) { |response| last_modified(response["last-modified"]) }
      end

      # Returns [true|false] whether the file exists, see `#exist?`. HTTP has no directories, so every url that
      # exists is a file.
      def file?
        exist?
      end

      # Returns false, since HTTP has no directories.
      def directory?
        authorize!
        false
      end

      # Returns [true|false] whether the file exists and has a Content-Length of zero, using an HTTP HEAD.
      def empty?
        size&.zero? || false
      rescue Errors::NotFound
        false
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

      # Returns [String] the url without the user name, password, query or fragment, see #loggable.
      def display_name
        loggable(URI.parse(url))
      end

      protected

      # Urls with the same scheme, host and port are in the same store, see `IOStreams::Path#same_store?`.
      def store = [original_uri.scheme, original_uri.hostname.to_s.downcase, original_uri.port]

      # Returns [String] the parts of the url that identify the file, see `IOStreams::Path#identity`, as the url
      # `scheme://host:port/path?query`: its store, see #store, so the scheme and the host in lower case, since they are
      # not case-sensitive, and the port unless it is the default port of the scheme, 80 or 443, then its path and its
      # query, which can name another file, with their percent-encoded characters spelled as RFC 3986 normalizes them,
      # see `IOStreams::Utils::URI.normalize_escapes`: so `%7E` is `~`, but `%2F` is not `/`, since a server can answer
      # them differently. The user name and password are not part of it, since they are credentials rather than part of
      # the name of the file, nor is the fragment, which is not sent to the server.
      def identity
        location(Utils::URI.normalize_escapes(original_uri.path))
      end

      # Returns [true|false] whether the other url is the same file, see `IOStreams::Path#same_location?`, also by
      # another spelling that most web servers answer with the same file: with the same #identity once its path is
      # decoded, see #path, and `.`, `..`, repeated `/` and a trailing `/` are resolved. So unlike #==, a percent-encoded
      # `/` is the same as `/`, since a server can decode it.
      def same_location?(other)
        other.instance_of?(self.class) && other.resolved_location == resolved_location
      end

      # Returns [String] the #identity of this url with its path resolved, see #same_location?.
      def resolved_location
        location(Utils::URI.encode_path(normalize_path(path)))
      end

      # Returns [String] the path with `.`, `..` and repeated `/` removed, see `IOStreams::Path#clean_name`, keeping a
      # trailing `/`, since a url that ends with it is another url, which a server can answer differently.
      def clean_name(name)
        clean = super
        name.end_with?("/") && !clean.end_with?("/") ? "#{clean}/" : clean
      end

      # Sets the path, also changing the url to use it, for example when called by `#join` or `#directory`.
      #
      # Each directory or file name that is unchanged keeps its encoding from the url, so that for example the
      # directory of `a%2541/b.csv` is still `a%2541`, rather than `a%41` from encoding its decoded name `a%41`.
      #
      # In a new name, such as from `#join`, characters that cannot appear in a url path, such as a space, `?`
      # or `#`, are percent-encoded in the url, as is every `%`, since the name is a name rather than part of a url.
      def path=(path)
        super
        uri           = URI.parse(url)
        encoded       = uri.path.split("/", -1)
        uri.path      = self.path.split("/", -1).each_with_index.map do |name, index|
          encoded[index] && URI.decode_uri_component(encoded[index]) == name ? encoded[index] : escape_path(name)
        end.join("/")
        @url = uri.to_s
        @original_uri_cache.clear
      end

      private

      # A copy has its own cached `#original_uri`, since it can be changed to a different url, for example
      # by `#join` or `#directory`.
      def initialize_copy(source)
        super
        @original_uri_cache = {}
      end

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

      # Characters that can appear in a name in a url path as they are. A `%` cannot, since it starts a percent-encoded
      # character.
      PATH_CHARACTERS = %r{[A-Za-z0-9\-._~!$&'()*+,;=:@/]}
      private_constant :PATH_CHARACTERS

      # Returns [String] the name with each character that cannot appear in a url path as it is percent-encoded.
      def escape_path(name)
        name.each_char.map { |char| char.match?(PATH_CHARACTERS) ? char : URI.encode_uri_component(char) }.join
      end

      # Returns [String] the url of the supplied path, as a url writes it, on the server of this url, see #store, with the
      # query of this url, in the spelling that #identity compares.
      def location(url_path)
        scheme, host, port = store
        query              = "?#{Utils::URI.normalize_escapes(original_uri.query)}" if original_uri.query
        "#{scheme}://#{Utils::URI.host_and_port(host, port, original_uri.default_port)}#{url_path}#{query}"
      end

      attr_reader :allow_hosts, :maximum_file_size, :headers

      # Returns [Time] the time of the Last-Modified header, or nil when it is not supplied, or is not a time, which is
      # logged as a warning via `IOStreams.logger`, since the file can still be read.
      def last_modified(header)
        header && Time.httpdate(header)
      rescue ArgumentError
        IOStreams.logger&.warn("Ignoring the Last-Modified header of #{display_name}, which is not a time: #{header.inspect}")
        nil
      end

      # Returns [Hash<String, String>] the supplied headers, frozen.
      def validate_headers(headers)
        return {}.freeze if headers.nil?
        raise(ArgumentError, "headers: must be a Hash, not #{headers.class}") unless headers.is_a?(Hash)

        headers.to_h { |name, value| [name.to_s.freeze, value.to_s.freeze] }.freeze
      end

      # Read a file using an http get.
      #
      # For example:
      #   IOStreams.path('https://example.com/files/data.zip').reader {|file| puts file.read}
      #
      # Read the file without unzipping and streaming the first file in the zip:
      #   IOStreams.path('https://example.com/files/data.zip').raw.reader {|file| puts file.read}
      #
      # Notes:
      # * The body is read one chunk at a time as the block reads it, see `BodyReader`, so the connection stays open
      #   while the block runs, and is closed once it returns.
      # * The request is made before the block is called, so that a failure of it, such as a missing file, raises
      #   before the block runs, and before `#copy_from` opens its target.
      # * A file that is read through streams that neither compress nor encrypt it, such as `data.csv`, is requested
      #   compressed, so that it is sent faster, and its body is decompressed as it is read, see #compress_in_transit?
      #   and `ContentCoding`. A Content-Encoding that cannot be decoded raises before the block runs.
      def stream_reader(&)
        coding  = nil
        request = lambda do |&each_chunk|
          send_request(Net::HTTP::Get, url, http_redirect_count) do |response|
            # Before the body is read, so that a content coding that cannot be decoded raises before the block runs.
            coding = compress_in_transit? ? ContentCoding.of(response, display_name) : ContentCoding::AS_SENT
            read_body(response, &each_chunk)
          end
        end
        BodyReader.open(request) do |body|
          coding.reader(body, maximum_size: maximum_file_size) { |input| builder.reader(input, &) }
        end
      end

      # Write a file using an http put.
      #
      # For example:
      #   IOStreams.path('https://example.com/upload/file.csv').write("name,age\njack,21\n")
      #
      # Notes:
      # * The data is written to a tempfile first, and then uploaded in a single request once
      #   the block completes, so that the server receives its size in the Content-Length header.
      #   It is uploaded when the block leaves early, such as with `break`, as a local file keeps what
      #   was written, but not when the block raises, or its thread is killed, see
      #   `IOStreams::Utils.finish_or_abort`.
      # * Only a 307 or 308 redirect to the same scheme, host, and port is followed when writing.
      #   The other redirects change the request into a GET, which would discard the upload, and
      #   a redirect to another server would send it the data being uploaded.
      def stream_writer(&)
        if maximum_file_size
          raise(ArgumentError, "maximum_file_size: only applies when reading from an HTTP path, not when writing")
        end

        upload = ->(file_name) { send_request(Net::HTTP::Put, url, http_redirect_count, body_file_name: file_name) { |_response| nil } }
        spooled_writer("iostreams_http", upload: upload, &)
      end

      # Sends the request, following redirects, and returns the result of the block, which is called
      # with the successful response.
      #
      # When a body_file_name is supplied its contents are sent as the body of the request.
      # When allow_missing is true, returns nil without calling the block when the server responds with
      # 404 Not Found or 410 Gone.
      #
      # The block is part of the request, such as downloading the response, so a failure of the connection within it is
      # tagged as a failure of the request, see `#failure_kind`.
      #
      # A redirect is followed once the connection that returned it is closed, so that the connection is not held open
      # while the block reads the body of the next one.
      def send_request(request_class, uri, http_redirect_count, body_file_name: nil, allow_missing: false, &block)
        uri      = URI.parse(uri) unless uri.is_a?(URI)
        result   = nil
        redirect = nil

        validate_uri!(uri)

        tag_failure do
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
            request = build_request(request_class, uri)
            body    = body_file_name ? ::File.open(body_file_name, "rb") : nil
            if body
              request.body_stream    = body
              request.content_length = body.size
              request.content_type   = "application/octet-stream" unless request["content-type"]
            end

            begin
              http.request(request) do |response|
                # A failure once the response has arrived must not send the request again, as Net::HTTP before v0.5
                # does for a GET, since the block may already have passed part of the body on to the application.
                http.max_retries = 0
                return nil if allow_missing && (response.is_a?(Net::HTTPNotFound) || response.is_a?(Net::HTTPGone))

                if response.is_a?(Net::HTTPRedirection)
                  redirect = redirect_uri(uri, response, http_redirect_count, request_class)
                  # Without reading the body of the redirect.
                  break
                end

                raise_failure(response, uri) unless response.is_a?(Net::HTTPSuccess)

                result = block.call(response)
              end
            ensure
              body&.close
            end
          end
        end
        return result unless redirect

        send_request(request_class, redirect, http_redirect_count - 1, body_file_name:, allow_missing:, &block)
      end

      # Returns [URI] the location of a redirect, resolved against the url that redirected.
      #
      # Raises [IOStreams::Errors::CommunicationsFailure] when the location is not a url, without the location in its
      # message, which the server supplies, and which can hold a token, unlike the message of `URI::InvalidURIError`.
      def redirect_location(uri, location)
        uri.merge(location)
      rescue URI::Error
        raise(IOStreams::Errors::CommunicationsFailure, "Redirect to a location that is not a url: #{loggable(uri)}",
              cause: nil)
      end

      # Returns [Module] the kind of failure that an exception raised by a request means, see `Failure.kind`.
      def failure_kind(exception)
        Failure.kind(exception)
      end

      # Raises [IOStreams::Errors::CommunicationsFailure] for the unsuccessful response, tagged with the kind of failure
      # that it means, see `Failure.response_kind`.
      def raise_failure(response, uri)
        message =
          case response
          when Net::HTTPNotFound
            "Invalid URL: #{loggable(uri)}"
          when Net::HTTPUnauthorized
            "Authorization Required: Invalid :username or :password."
          else
            "Invalid response code: #{response.code}"
          end
        error = Errors::CommunicationsFailure.new(message)
        kind  = Failure.response_kind(response)
        raise(kind ? kind.tag(error, display_name) : error)
      end

      # Returns [Net::HTTPRequest] the request, with the supplied headers and credentials
      # when it is sent to the original host, and its Accept-Encoding, see #accept_encoding.
      def build_request(request_class, uri)
        # Only send headers and credentials to the original host to avoid leaking them via a redirect.
        original        = same_origin?(uri)
        accept_encoding = accept_encoding(request_class)
        # Supplied when the request is created, so that Net::HTTP never decodes the body.
        request         = request_class.new(uri, accept_encoding ? {"Accept-Encoding" => accept_encoding} : nil)
        (original ? headers : {}).each do |name, value|
          request[name] = value unless accept_encoding && name.casecmp?("accept-encoding")
        end
        request.basic_auth(username, password) if original && username
        request
      end

      # Returns [String] the Accept-Encoding of a request whose response body is read, or nil for a PUT or DELETE:
      # * a HEAD accepts only identity, so that its Content-Length is the size of the file as it is stored;
      # * a GET sends the Accept-Encoding supplied with `headers:`, and the body is then read as it is sent, see
      #   #compress_in_transit?. Unlike the other supplied headers it is sent to every host, since it holds no
      #   credential, so that the body is read the same way after a redirect;
      # * otherwise a GET asks for a body that the server compresses while it sends it, when #compress_in_transit?,
      #   and for the file as it is stored when not.
      def accept_encoding(request_class)
        return ContentCoding::IDENTITY if request_class == Net::HTTP::Head
        return unless request_class == Net::HTTP::Get
        return ContentCoding::ACCEPT_ENCODING if compress_in_transit?

        supplied_header("accept-encoding") || ContentCoding::IDENTITY
      end

      # Returns [true|false] whether a GET asks the server to compress the body while it sends it, which is then
      # decompressed as it is read, see `ContentCoding`: when this path reads its data through streams that neither
      # compress nor encrypt it, such as `data.csv`, a `.parquet` file, or a url without an extension, and `headers:`
      # do not supply an Accept-Encoding.
      #
      # A compressed or encrypted file, such as `data.csv.gz`, and a file read as it is stored, see #raw, are requested
      # as they are stored: their data does not compress further, a Content-Encoding that the server sends with them,
      # such as `gzip` for a `.gz` file, belongs to the file as it is stored, which their own streams decode, and a
      # server that compresses every response would otherwise compress them again.
      def compress_in_transit?
        !raw? && !compressed? && !encrypted? && supplied_header("accept-encoding").nil?
      end

      # Returns [String] the value of the header supplied with `headers:`, whatever the case of its name, or nil.
      def supplied_header(name)
        headers.find { |key, _value| key.casecmp?(name) }&.last
      end

      # Returns [URI] the location to redirect to, resolved against the current uri.
      def redirect_uri(uri, response, http_redirect_count, request_class)
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
        new_uri = redirect_location(uri, location)

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

      # Validate that the host may be contacted, and that the scheme is still http(s)
      # after following a redirect.
      #
      # A redirect must also be within the allowed paths, see `IOStreams.add_allowed_path`.
      def validate_uri!(uri)
        unless %w[http https].include?(uri.scheme)
          raise(IOStreams::Errors::CommunicationsFailure,
                "Invalid redirect, only http and https are supported: #{loggable(uri)}")
        end
        authorize_location!(http_location(uri)) unless IOStreams.allowed_paths.empty?
        return if allow_hosts.nil? || allow_hosts.any? { |host| host.to_s.casecmp?(uri.hostname.to_s) }

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
        raise(Errors::AccessDenied, "Access denied: #{loggable(uri)} has no host") if uri.host.to_s.empty?

        path = URI.decode_uri_component(uri.path).tr("\\", "/")
        "#{uri.scheme}://#{uri.host.downcase}:#{uri.port}#{normalize_path(path)}".chomp("/")
      rescue ArgumentError => e
        raise(Errors::AccessDenied, "Access denied to #{loggable(uri)}: #{e.message}")
      end

      # Returns [String] the uri without any user name, password, query or fragment, for logging, and for the message
      # of an error. The query is removed since it can hold credentials, such as the signature of a pre-signed url, or
      # the `parameters:` supplied to this path.
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
        @original_uri_cache[:uri] ||= URI.parse(url)
      end

      # Yields each chunk of the body of the response as it is received, raising when the bytes received exceed the maximum
      # file size, before any content coding is decoded, see `ContentCoding`.
      #
      # Raises [IOStreams::Errors::CommunicationsFailure], tagged as `Unavailable`, when the connection closes before the
      # whole body has been received, rather than EOFError, which the application would take for the end of the body,
      # since it reads the body as it is received.
      def read_body(response)
        size = 0
        # Rather than accepting a body that is shorter than its Content-Length.
        response.ignore_eof = false
        response.read_body do |chunk|
          size += chunk.bytesize
          if maximum_file_size && (size > maximum_file_size)
            raise(
              IOStreams::Errors::CommunicationsFailure,
              "Exceeded maximum allowed download size of #{maximum_file_size} bytes"
            )
          end
          yield(chunk)
        end
      rescue EOFError
        error = Errors::CommunicationsFailure.new("The connection closed before the whole body was received")
        raise(Errors::Unavailable.tag(error, display_name))
      end
    end
  end
end
