require_relative "../test_helper"
require "socket"
require "base64"

module Paths
  class HTTPTest < Minitest::Test
    # Minimal HTTP server used to exercise redirect, credential, allow-list,
    # download-size and upload handling without depending on an external service.
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
        reason = {200 => "OK", 201 => "Created", 204 => "No Content", 301 => "Moved Permanently", 302 => "Found",
                  307 => "Temporary Redirect", 308 => "Permanent Redirect", 401 => "Unauthorized",
                  404 => "Not Found", 405 => "Method Not Allowed", 500 => "Internal Server Error"}[status]
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
        body    = headers["content-length"] ? client.read(headers["content-length"].to_i) : nil
        request = {method: method, path: path, headers: headers, body: body}
        @requests << request
        client.write(@handler.call(path, request))
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

        it "does not include credentials in error messages" do
          start_server { |_path| TestHTTPServer.response(404) }
          url = "http://jack:TOP-SECRET@127.0.0.1:#{@server.port}/missing"

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new(url).read
          end
          refute_includes error.message, "TOP-SECRET"
          refute_includes error.message, "jack"
          assert_includes error.message, "http://127.0.0.1:#{@server.port}/missing"
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

        it "adds supplied parameters to a url that has a query string" do
          start_server { |_path| TestHTTPServer.response(200, body: body) }

          url = "#{@server.base_url}/file?a=1&token=old&b=2&token=older#section"
          path = IOStreams.path(url, parameters: {token: "new", q: "search term"})

          assert_equal "#{@server.base_url}/file?a=1&b=2&token=new&q=search+term#section", path.to_s
          path.read

          assert_equal "/file?a=1&b=2&token=new&q=search+term", @server.requests.first[:path]
        end

        it "leaves the url unchanged without parameters" do
          url = "https://example.org/file?a=1"

          assert_equal url, IOStreams.path(url, parameters: {}).to_s
        end

        it "downloads the joined path" do
          start_server { |path| TestHTTPServer.response(200, body: "Requested #{path}") }

          path = IOStreams.path("#{@server.base_url}/files?token=abc").join("2024", "report 1.csv")

          assert_equal "#{@server.base_url}/files/2024/report%201.csv?token=abc", path.to_s
          assert_equal "Requested /files/2024/report%201.csv?token=abc", path.read
        end

        it "downloads the directory" do
          start_server { |path| TestHTTPServer.response(200, body: "Requested #{path}") }

          assert_equal "Requested /files", IOStreams.path("#{@server.base_url}/files/report.csv").directory.read
        end

        it "encodes characters in a joined name that would change the url" do
          path = IOStreams.path("https://example.com/files").join("a?b#c.csv")

          assert_equal "https://example.com/files/a%3Fb%23c.csv", path.to_s
          assert_equal "/files/a?b#c.csv", path.path
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

        describe "allowed paths" do
          after do
            IOStreams.instance_variable_set(:@allowed_paths, [].freeze)
          end

          it "downloads a url within an allowed path" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }
            IOStreams.add_allowed_path("#{@server.base_url}/files")

            assert_equal body, IOStreams.path("#{@server.base_url}/files/report.csv").read
          end

          it "uploads to a url within an allowed path" do
            start_server { |_path| TestHTTPServer.response(201) }
            IOStreams.add_allowed_path("#{@server.base_url}/files")

            IOStreams.path("#{@server.base_url}/files/report.csv").write(body)

            assert_equal body, @server.requests.first[:body]
          end

          it "denies an upload outside the allowed paths without contacting the server" do
            start_server { |_path| TestHTTPServer.response(201) }
            IOStreams.add_allowed_path("#{@server.base_url}/files")

            assert_raises IOStreams::Errors::AccessDenied do
              IOStreams.path("#{@server.base_url}/secret.csv").write(body)
            end
            assert_empty @server.requests
          end

          it "denies a redirected upload outside the allowed paths" do
            start_server { |_path| TestHTTPServer.response(307, headers: {"Location" => "/secret.csv"}) }
            IOStreams.add_allowed_path("#{@server.base_url}/files")

            assert_raises IOStreams::Errors::AccessDenied do
              IOStreams.path("#{@server.base_url}/files/report.csv").write(body)
            end
            assert_equal 1, @server.requests.size
          end

          it "denies a joined path outside the allowed paths without contacting the server" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }
            IOStreams.add_allowed_path("#{@server.base_url}/files/public")

            assert_raises IOStreams::Errors::AccessDenied do
              IOStreams.path("#{@server.base_url}/files/public").join("..", "secret.csv").read
            end
            assert_empty @server.requests
          end

          it "denies a url outside the allowed paths without contacting the server" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }
            IOStreams.add_allowed_path("#{@server.base_url}/files")

            assert_raises IOStreams::Errors::AccessDenied do
              IOStreams.path("#{@server.base_url}/secret").read
            end
            assert_empty @server.requests
          end

          it "denies a redirect outside the allowed paths" do
            start_server do |path|
              if path == "/files/report.csv"
                TestHTTPServer.response(302, headers: {"Location" => "/secret"})
              else
                TestHTTPServer.response(200, body: "secret")
              end
            end
            IOStreams.add_allowed_path("#{@server.base_url}/files")

            assert_raises IOStreams::Errors::AccessDenied do
              IOStreams.path("#{@server.base_url}/files/report.csv").read
            end
            assert_equal(["/files/report.csv"], @server.requests.collect { |request| request[:path] })
          end

          it "follows a redirect within the allowed paths" do
            start_server do |path|
              if path == "/files/report.csv"
                TestHTTPServer.response(302, headers: {"Location" => "/files/moved.csv"})
              else
                TestHTTPServer.response(200, body: body)
              end
            end
            IOStreams.add_allowed_path("#{@server.base_url}/files")

            assert_equal body, IOStreams.path("#{@server.base_url}/files/report.csv").read
          end
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
        describe "#write" do
          it "uploads the file with a put" do
            start_server { |_path| TestHTTPServer.response(201) }

            IOStreams::Paths::HTTP.new("#{@server.base_url}/upload/file.txt").write(body)

            request = @server.requests.first

            assert_equal "PUT", request[:method]
            assert_equal "/upload/file.txt", request[:path]
            assert_equal body, request[:body]
            assert_equal body.bytesize.to_s, request[:headers]["content-length"]
            assert_equal "application/octet-stream", request[:headers]["content-type"]
          end

          it "accepts a 204 No Content response" do
            start_server { |_path| TestHTTPServer.response(204) }

            IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt").write(body)

            assert_equal body, @server.requests.first[:body]
          end

          it "returns the result of the block" do
            start_server { |_path| TestHTTPServer.response(200) }

            result = IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt").writer do |io|
              io.write(body)
              :done
            end

            assert_equal :done, result
          end

          it "applies the streams for the file name" do
            start_server { |_path| TestHTTPServer.response(200) }

            IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt.gz").write(body)

            assert_equal body, Zlib.gunzip(@server.requests.first[:body])
          end

          it "writes lines" do
            start_server { |_path| TestHTTPServer.response(200) }

            IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt").writer(:line) do |io|
              io << "one"
              io << "two"
            end

            assert_equal "one\ntwo\n", @server.requests.first[:body]
          end

          it "uploads an empty file" do
            start_server { |_path| TestHTTPServer.response(200) }

            IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt").writer { |_io| nil }

            assert_equal "0", @server.requests.first[:headers]["content-length"]
          end

          it "sends the supplied headers" do
            start_server { |_path| TestHTTPServer.response(200) }

            IOStreams::Paths::HTTP.new(
              "#{@server.base_url}/file.csv",
              headers: {"Content-Type" => "text/csv", :"X-Custom" => "value"}
            ).write(body)

            headers = @server.requests.first[:headers]

            assert_equal "text/csv", headers["content-type"]
            assert_equal "value", headers["x-custom"]
          end

          it "sends basic auth credentials" do
            start_server { |_path| TestHTTPServer.response(200) }

            IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt", username: "jack", password: "secret").write(body)

            assert auth = @server.requests.first[:headers]["authorization"]
            assert_equal %w[jack secret], Base64.decode64(auth.sub(/\ABasic /, "")).split(":")
          end

          it "raises when the server requires authorization" do
            start_server { |_path| TestHTTPServer.response(401) }

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt").write(body)
            end
            assert_includes error.message, "Authorization Required"
          end

          it "raises on an unsuccessful response code" do
            start_server { |_path| TestHTTPServer.response(405) }

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt").write(body)
            end
            assert_includes error.message, "405"
          end

          it "follows a 307 redirect, resending the body" do
            start_server do |path|
              if path == "/redirect"
                TestHTTPServer.response(307, headers: {"Location" => "/file.txt"})
              else
                TestHTTPServer.response(201)
              end
            end

            IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect").write(body)

            assert_equal 2, @server.requests.size
            target = @server.requests.last

            assert_equal "PUT", target[:method]
            assert_equal "/file.txt", target[:path]
            assert_equal body, target[:body]
          end

          it "follows a 308 redirect" do
            start_server do |path|
              if path == "/redirect"
                TestHTTPServer.response(308, headers: {"Location" => "/file.txt"})
              else
                TestHTTPServer.response(201)
              end
            end

            IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect").write(body)

            assert_equal body, @server.requests.last[:body]
          end

          it "does not follow a redirect that would change the upload into a get" do
            [301, 302].each do |status|
              @server&.shutdown
              start_server { |_path| TestHTTPServer.response(status, headers: {"Location" => "/file.txt"}) }

              error = assert_raises IOStreams::Errors::CommunicationsFailure do
                IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect").write(body)
              end
              assert_includes error.message, "Only a 307 or 308 redirect"
              assert_equal 1, @server.requests.size
            end
          end

          it "does not resend credentials across a redirect to another host" do
            @other = TestHTTPServer.new { |_path| TestHTTPServer.response(201) }
            start_server { |_path| TestHTTPServer.response(307, headers: {"Location" => "#{@other.base_url}/file.txt"}) }

            IOStreams::Paths::HTTP.new(
              "#{@server.base_url}/redirect",
              username: "jack", password: "secret",
              headers: {"Cookie" => "session=1", "Proxy-Authorization" => "Basic abc", "Content-Type" => "text/plain"}
            ).write(body)

            original = @server.requests.first[:headers]

            refute_nil original["authorization"]
            assert_equal "session=1", original["cookie"]

            redirected = @other.requests.first

            assert_equal body, redirected[:body]
            assert_nil redirected[:headers]["authorization"]
            assert_nil redirected[:headers]["cookie"]
            assert_nil redirected[:headers]["proxy-authorization"]
            # Headers without credentials are still sent.
            assert_equal "text/plain", redirected[:headers]["content-type"]
          end

          it "rejects a redirect to a host outside the allow list" do
            @other = TestHTTPServer.new { |_path| TestHTTPServer.response(201) }
            start_server { |_path| TestHTTPServer.response(307, headers: {"Location" => "#{@other.base_url}/file.txt"}) }

            assert_raises IOStreams::Errors::CommunicationsFailure do
              IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect", allow_hosts: "localhost").write(body)
            end
            assert_empty @other.requests
          end

          it "rejects a maximum_file_size, which only applies when reading" do
            start_server { |_path| TestHTTPServer.response(200) }

            error = assert_raises ArgumentError do
              IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt", maximum_file_size: 10).write(body)
            end
            assert_includes error.message, "maximum_file_size"
            assert_empty @server.requests
          end
        end

        describe "headers:" do
          it "sends the supplied headers when reading" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }

            IOStreams::Paths::HTTP.new("#{@server.base_url}/file", headers: {"Authorization" => "Bearer token"}).read

            assert_equal "Bearer token", @server.requests.first[:headers]["authorization"]
          end

          it "rejects headers that are not a hash" do
            error = assert_raises ArgumentError do
              IOStreams::Paths::HTTP.new("http://example.com/file", headers: "Authorization: Bearer token")
            end
            assert_includes error.message, "headers:"
          end
        end
      end
    end
  end
end
