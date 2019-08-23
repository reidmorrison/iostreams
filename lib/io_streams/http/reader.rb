require 'net/http'
require 'uri'
module IOStreams
  module HTTP
    # Read a file using an http get.
    #
    # For example:
    #   IOStreams.reader('https://www5.fdic.gov/idasp/Offices2.zip') {|file| puts file.read}
    #
    # Direct example without unzipping the above file:
    #   IOStreams::HTTP::Reader.new('https://www5.fdic.gov/idasp/Offices2.zip') {|file| puts file.read}
    #
    # Parameters:
    #   uri: [String|URI]
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
    class Reader
      def self.open(uri, username: nil, password: nil, **args, &block)
        raise(ArgumentError, 'file_name must be a URI string') unless uri.is_a?(String) || uri.is_a?(URI)
        handle_redirects(uri, username: username, password: password, **args, &block)
      end

      def self.handle_redirects(uri, username: nil, password: nil, http_redirect_count: 10, **args, &block)
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
              return handle_redirects(new_uri, username: username, password: password, http_redirect_count: http_redirect_count - 1, **args, &block)
            end

            raise(IOStreams::Errors::CommunicationsFailure, "Invalid response code: #{response.code}") unless response.is_a?(Net::HTTPSuccess)

            # Since Net::HTTP download only supports a push stream, write it to a tempfile first.
            IOStreams::File::Path.temp_file_name('iostreams_http') do |file_name|
              IOStreams::File::Writer.open(file_name) do |io|
                response.read_body { |chunk| io.write(chunk) }
              end
              # Return a read stream
              result = IOStreams::File::Reader.open(file_name, &block)
            end
          end
        end
        result
      end
    end
  end
end
