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
        reason = {200 => "OK", 302 => "Found", 401 => "Unauthorized", 404 => "Not Found"}[status]
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
      end
    end
  end
end
