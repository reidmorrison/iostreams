require_relative "../test_helper"
require "socket"
require "base64"

module Paths
  class HTTPTest < Minitest::Test
    # Minimal HTTP server used to exercise redirect, credential, allow-list and
    # download-size handling without depending on an external service.
    class TestHTTPServer
      attr_reader :port, :requests

      def initialize(&handler)
        @handler  = handler
        @requests = []
        @server   = TCPServer.new("127.0.0.1", 0)
        @port     = @server.addr[1]
        @thread   = Thread.new { serve }
      end

      def base_url
        "http://127.0.0.1:#{port}"
      end

      def shutdown
        @thread&.kill
        @server&.close
      rescue StandardError
        nil
      end

      # Build a raw HTTP response string.
      def self.response(status, body: "", headers: {})
        reason = {200 => "OK", 302 => "Found", 401 => "Unauthorized", 404 => "Not Found",
                  500 => "Internal Server Error"}[status]
        all    = {"Content-Length" => body.bytesize.to_s, "Connection" => "close"}.merge(headers)
        lines  = ["HTTP/1.1 #{status} #{reason}"]
        all.each { |key, value| lines << "#{key}: #{value}" }
        lines << ""
        lines << body
        lines.join("\r\n")
      end

      private

      def serve
        loop do
          client = @server.accept
          handle_client(client)
        end
      rescue IOError, Errno::EBADF
        # Server was shut down.
      end

      def handle_client(client)
        request_line = client.gets
        return if request_line.nil?

        method, path, = request_line.split
        headers = {}
        while (line = client.gets) && line != "\r\n"
          key, value                  = line.split(":", 2)
          headers[key.strip.downcase] = value.to_s.strip
        end
        @requests << {method: method, path: path, headers: headers}
        client.write(@handler.call(path))
      ensure
        client&.close
      end
    end

    describe IOStreams::Paths::HTTP do
      describe ".new" do
        it "rejects a non-http(s) scheme" do
          error = assert_raises ArgumentError do
            IOStreams::Paths::HTTP.new("ftp://example.com/file")
          end
          assert_includes error.message, "Invalid URL"
        end
      end

      describe ".open (live)" do
        let(:url) { "http://google.com" }
        let(:ssl_url) { "https://google.com" }

        it "reads http" do
          result = IOStreams::Paths::HTTP.new(url).read
          assert_includes result, "Google"
        end

        it "reads https" do
          result = IOStreams::Paths::HTTP.new(ssl_url).read
          assert_includes result, "Google"
        end

        it "does not support streams" do
          assert_raises URI::InvalidURIError do
            io = StringIO.new
            IOStreams::Paths::HTTP.new(io)
          end
        end
      end

      describe "with a local server" do
        let(:body) { "Hello World" }

        after do
          @server&.shutdown
          @other&.shutdown
        end

        def start_server(&block)
          @server = TestHTTPServer.new(&block)
        end

        it "downloads a file" do
          start_server { |_path| TestHTTPServer.response(200, body: body) }

          assert_equal body, IOStreams::Paths::HTTP.new("#{@server.base_url}/file").read
        end

        it "raises when the server returns 404 Not Found" do
          start_server { |_path| TestHTTPServer.response(404) }

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/missing").read
          end
          assert_includes error.message, "Invalid URL"
        end

        it "raises when the server requires authorization" do
          start_server { |_path| TestHTTPServer.response(401) }

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/file").read
          end
          assert_includes error.message, "Authorization Required"
        end

        it "raises on an unsuccessful response code" do
          start_server { |_path| TestHTTPServer.response(500) }

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/file").read
          end
          assert_includes error.message, "Invalid response code: 500"
        end

        it "appends supplied parameters to the url as a query string" do
          start_server { |_path| TestHTTPServer.response(200, body: body) }

          IOStreams::Paths::HTTP.new("#{@server.base_url}/file", parameters: {q: "search term", page: 2}).read
          path = @server.requests.first[:path]
          assert_includes path, "q=search+term"
          assert_includes path, "page=2"
        end

        it "follows a relative redirect" do
          start_server do |path|
            if path == "/redirect"
              TestHTTPServer.response(302, headers: {"Location" => "/file"})
            else
              TestHTTPServer.response(200, body: body)
            end
          end

          assert_equal body, IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect").read
        end

        it "raises when too many redirects are followed" do
          start_server { |_path| TestHTTPServer.response(302, headers: {"Location" => "/loop"}) }

          assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/loop", http_redirect_count: 2).read
          end
        end

        it "does not follow redirects when disabled" do
          start_server { |_path| TestHTTPServer.response(302, headers: {"Location" => "/file"}) }

          assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/file", http_redirect_count: 0).read
          end
        end

        it "raises when a redirect is missing the location header" do
          start_server { |_path| TestHTTPServer.response(302) }

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect").read
          end
          assert_includes error.message, "missing location"
        end

        it "rejects a redirect to a host outside the allow list" do
          # The initial host is allowed, but the server redirects to a different
          # host name (localhost) that is not, which is the core SSRF scenario.
          start_server { |_path| TestHTTPServer.response(302, headers: {"Location" => "http://localhost:#{@server.port}/file"}) }

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect", allow_hosts: ["127.0.0.1"]).read
          end
          assert_includes error.message, "not in the allowed list"
        end

        it "rejects a redirect to a non-http(s) scheme" do
          start_server { |_path| TestHTTPServer.response(302, headers: {"Location" => "ftp://127.0.0.1/secret"}) }

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect").read
          end
          assert_includes error.message, "only http and https"
        end

        it "aborts a download that exceeds the maximum file size" do
          start_server { |_path| TestHTTPServer.response(200, body: body) }

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/file", maximum_file_size: 5).read
          end
          assert_includes error.message, "maximum allowed download size"
        end

        it "rejects a host that is not in the allow list" do
          start_server { |_path| TestHTTPServer.response(200, body: body) }

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/file", allow_hosts: ["example.com"]).read
          end
          assert_includes error.message, "not in the allowed list"
        end

        it "allows a host that is in the allow list" do
          start_server { |_path| TestHTTPServer.response(200, body: body) }

          assert_equal body, IOStreams::Paths::HTTP.new("#{@server.base_url}/file", allow_hosts: ["127.0.0.1"]).read
        end

        it "accepts allow_hosts supplied as a single string" do
          start_server { |_path| TestHTTPServer.response(200, body: body) }

          assert_equal body, IOStreams::Paths::HTTP.new("#{@server.base_url}/file", allow_hosts: "127.0.0.1").read
        end

        it "downloads a body that is within the maximum file size" do
          start_server { |_path| TestHTTPServer.response(200, body: body) }

          assert_equal body, IOStreams::Paths::HTTP.new("#{@server.base_url}/file", maximum_file_size: body.bytesize).read
        end

        it "sends basic auth credentials to the original host" do
          start_server { |_path| TestHTTPServer.response(200, body: body) }

          IOStreams::Paths::HTTP.new("#{@server.base_url}/file", username: "jack", password: "secret").read
          assert auth = @server.requests.first[:headers]["authorization"]
          assert_equal %w[jack secret], Base64.decode64(auth.sub(/\ABasic /, "")).split(":")
        end

        it "does not resend credentials across a redirect to another host" do
          @other = TestHTTPServer.new { |_path| TestHTTPServer.response(200, body: body) }
          start_server { |_path| TestHTTPServer.response(302, headers: {"Location" => "#{@other.base_url}/file"}) }

          result = IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect", username: "jack", password: "secret").read
          assert_equal body, result

          # Credentials sent to the original host.
          refute_nil @server.requests.first[:headers]["authorization"]
          # But not leaked to the redirect target.
          assert_nil @other.requests.first[:headers]["authorization"]
        end

        it "resends credentials across a same-origin redirect" do
          start_server do |path|
            if path == "/redirect"
              TestHTTPServer.response(302, headers: {"Location" => "/file"})
            else
              TestHTTPServer.response(200, body: body)
            end
          end

          result = IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect", username: "jack", password: "secret").read
          assert_equal body, result

          # Same scheme, host and port, so credentials are sent on both requests.
          assert_equal 2, @server.requests.size
          assert(@server.requests.all? { |request| request[:headers]["authorization"] })
        end
      end
    end
  end
end
