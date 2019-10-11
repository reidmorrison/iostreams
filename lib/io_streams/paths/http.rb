require 'net/http'
require 'uri'
module IOStreams
  module Paths
    class HTTP < IOStreams::Path
      attr_reader :username, :password, :http_redirect_count

      def initialize(url, username: nil, password: nil, http_redirect_count: 10)
        @username            = username
        @password            = password
        @http_redirect_count = http_redirect_count
        super(url)
      end

      # Read a file using an http get.
      #
      # For example:
      #   IOStreams.path('https://www5.fdic.gov/idasp/Offices2.zip').reader {|file| puts file.read}
      #
      # Read the file without unzipping and streaming the first file in the zip:
      #   IOStreams.path('https://www5.fdic.gov/idasp/Offices2.zip').stream(:none).reader {|file| puts file.read}
      #
      # Parameters:
      #   url: [String|URI]
      #      URI of the file to download.
      #     Example:
      #       https://www5.fdic.gov/idasp/Offices2.zip
      #
      #   :username
      #     When supplied, basic authentication is used with the username and password.
      #     Default: nil
      #
      #   :password
      #     Password to use use with basic authentication when the username is supplied.
      #
      # Notes:
      # * Since Net::HTTP download only supports a push stream, the data is streamed into a tempfile first.
      def reader(&block)
        handle_redirects(uri, http_redirect_count, &block)
      end

      def handle_redirects(uri, http_redirect_count, &block)
        uri    = URI.parse(uri) unless uri.is_a?(URI)
        result = nil
        raise(IOStreams::Errors::CommunicationsFailure, "Too many redirects") if http_redirect_count < 1

        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
          request = Net::HTTP::Get.new(uri)
          request.basic_auth(username, password) if username

          http.request(request) do |response|
            if response.is_a?(Net::HTTPNotFound)
              raise(IOStreams::Errors::CommunicationsFailure, "Invalid URL: #{uri}")
            end
            if response.is_a?(Net::HTTPUnauthorized)
              raise(IOStreams::Errors::CommunicationsFailure, "Authorization Required: Invalid :username or :password.")
            end

            if response.is_a?(Net::HTTPRedirection)
              new_uri = response['location']
              return handle_redirects(new_uri, http_redirect_count: http_redirect_count - 1, &block)
            end

            unless response.is_a?(Net::HTTPSuccess)
              raise(IOStreams::Errors::CommunicationsFailure, "Invalid response code: #{response.code}")
            end

            # Since Net::HTTP download only supports a push stream, write it to a tempfile first.
            IOStreams::Paths::File.temp_file_name('iostreams_http') do |file_name|
              IOStreams::Paths::File.new(file_name).writer do |io|
                response.read_body { |chunk| io.write(chunk) }
              end
              # Return a read stream
              result = IOStreams::Paths::File.new(file_name).reader(&block)
            end
          end
        end
        result
      end
    end
  end
end
