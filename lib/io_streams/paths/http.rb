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
      def initialize(url, username: nil, password: nil, http_redirect_count: 10, parameters: nil)
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
        raise(IOStreams::Errors::CommunicationsFailure, "Too many redirects") if http_redirect_count < 1

        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          request = Net::HTTP::Get.new(uri)
          request.basic_auth(username, password) if username

          http.request(request) do |response|
            raise(IOStreams::Errors::CommunicationsFailure, "Invalid URL: #{uri}") if response.is_a?(Net::HTTPNotFound)
            if response.is_a?(Net::HTTPUnauthorized)
              raise(IOStreams::Errors::CommunicationsFailure, "Authorization Required: Invalid :username or :password.")
            end

            if response.is_a?(Net::HTTPRedirection)
              new_uri = response["location"]
              return handle_redirects(new_uri, http_redirect_count - 1, &block)
            end

            unless response.is_a?(Net::HTTPSuccess)
              raise(IOStreams::Errors::CommunicationsFailure, "Invalid response code: #{response.code}")
            end

            # Since Net::HTTP download only supports a push stream, write it to a tempfile first.
            Utils.temp_file_name("iostreams_http") do |file_name|
              ::File.open(file_name, "wb") { |io| response.read_body { |chunk| io.write(chunk) } }
              # Return a read stream
              result = ::File.open(file_name, "rb") { |io| builder.reader(io, &block) }
            end
          end
        end
        result
      end
    end
  end
end
