require_relative "../test_helper"
require_relative "../http_server"
require "socket"
require "base64"
require "logger"
require "openssl"

module Paths
  class HTTPTest < Minitest::Test
    describe IOStreams::Paths::HTTP do
      describe ".new" do
        it "rejects a non-http(s) scheme" do
          error = assert_raises ArgumentError do
            IOStreams::Paths::HTTP.new("ftp://example.com/file")
          end
          assert_includes error.message, "Invalid URL"
        end
      end

      describe "#path" do
        it "decodes the url path" do
          path = IOStreams::Paths::HTTP.new("https://example.com/a%20b/my%20file+1.csv")

          assert_equal "/a b/my file+1.csv", path.path
          assert_equal "my file+1.csv", path.basename
          assert_equal "https://example.com/a%20b/my%20file+1.csv", path.to_s
        end

        it "is the root path for a url without a path" do
          %w[https://example.com https://example.com/ https://example.com?a=1].each do |url|
            assert_equal "/", IOStreams::Paths::HTTP.new(url).path, url
          end
        end
      end

      describe "#to_s" do
        it "returns the root path of a url without a path" do
          %w[https://example.com https://example.com/].each do |url|
            path = IOStreams::Paths::HTTP.new(url)

            assert_equal "https://example.com/", path.to_s, url
            assert_equal path.directory, path, url
          end
          assert_equal "https://example.com/?a=1#b", IOStreams::Paths::HTTP.new("https://example.com?a=1#b").to_s
          assert_equal "https://example.com/?a=1", IOStreams::Paths::HTTP.new("https://example.com", parameters: {a: 1}).to_s
          assert_equal IOStreams::Paths::HTTP.new("https://example.com"), IOStreams::Paths::HTTP.new("https://example.com/")
        end
      end

      describe "#absolute?" do
        it "is always true" do
          %w[https://example.com https://example.com/a.csv].each do |url|
            path = IOStreams::Paths::HTTP.new(url)

            assert_predicate path, :absolute?, url
            refute_predicate path, :relative?, url
          end
        end
      end

      describe "#blank?" do
        it "is false without making a request" do
          path = IOStreams::Paths::HTTP.new("https://server/path")

          Net::HTTP.stub(:start, ->(*) { flunk "blank? must not make a request" }) do
            refute_predicate path, :blank?
          end
        end
      end

      describe "#directory" do
        it "returns the host for a url without a directory" do
          %w[https://example.com https://example.com/ https://example.com/a.csv].each do |url|
            assert_equal "https://example.com/", IOStreams::Paths::HTTP.new(url).directory.to_s, url
          end
        end

        it "keeps the encoding of the directory" do
          path = IOStreams::Paths::HTTP.new("https://example.com/a%20b/c%2541/d.csv")

          assert_equal "https://example.com/a%20b/c%2541", path.directory.to_s
          assert_equal "/a b/c%41", path.directory.path
        end
      end

      describe "operations that HTTP does not support" do
        let(:path) { IOStreams.path("https://example.com/files/a.csv") }

        it "raises NotImplementedError naming the class, operation and path" do
          error = assert_raises(NotImplementedError) { path.delete_all }

          assert_equal "IOStreams::Paths::HTTP does not support #delete_all: https://example.com/files/a.csv", error.message
          assert_raises(NotImplementedError) { path.each_child { |_child| flunk } }
        end

        it "does not respond to them, like a method Ruby does not implement on the platform" do
          refute_respond_to path, :delete_all
          refute_respond_to path, :each_child
          assert_respond_to path, :exist?
          assert_respond_to path, :read
        end
      end

      describe "#join" do
        it "keeps a percent-encoded character in a joined name" do
          path = IOStreams::Paths::HTTP.new("https://example.com/files").join("my%20file.csv")

          assert_equal "https://example.com/files/my%20file.csv", path.to_s
        end

        it "encodes a % that is not percent-encoded in a joined name" do
          path = IOStreams::Paths::HTTP.new("https://example.com/files").join("100%.csv")

          assert_equal "https://example.com/files/100%25.csv", path.to_s
          assert_equal "100%.csv", path.basename
        end
      end

      it "does not support streams" do
        assert_raises URI::InvalidURIError do
          io = StringIO.new
          IOStreams::Paths::HTTP.new(io)
        end
      end

      describe "https with a local server" do
        after do
          @server&.shutdown
        end

        it "downloads a file" do
          @server = TestHTTPServer.new(tls: true) { |_path| TestHTTPServer.response(200, body: "Hello World") }

          TestHTTPServer.trust_certificate do
            assert_equal "Hello World", IOStreams::Paths::HTTP.new("#{@server.base_url}/file").read
          end
        end

        it "rejects a certificate that is not trusted" do
          @server = TestHTTPServer.new(tls: true) { |_path| TestHTTPServer.response(200, body: "Hello World") }

          error = assert_raises(OpenSSL::SSL::SSLError) { IOStreams::Paths::HTTP.new("#{@server.base_url}/file").read }
          assert_match(/certificate verify failed/i, error.message)
          assert_empty @server.requests
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
          assert_kind_of IOStreams::Errors::NotFound, error
        end

        it "raises NotFound when the server returns 410 Gone" do
          start_server { |_path| TestHTTPServer.response(410) }

          error = assert_raises IOStreams::Errors::NotFound do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/gone.csv").read
          end
          assert_instance_of IOStreams::Errors::CommunicationsFailure, error
          assert_equal "#{@server.base_url}/gone.csv: Invalid response code: 410", error.message
        end

        it "raises NotFound with the display name of the path, without its credentials or query" do
          start_server { |_path| TestHTTPServer.response(404) }
          url = "http://jack:TOP-SECRET@127.0.0.1:#{@server.port}/missing.csv?token=SECRET"

          error = assert_raises(IOStreams::Errors::NotFound) { IOStreams::Paths::HTTP.new(url).read }
          assert_equal "http://127.0.0.1:#{@server.port}/missing.csv", error.display_name
          refute_includes error.message, "TOP-SECRET"
        end

        it "does not tag any other unsuccessful response" do
          start_server { |_path| TestHTTPServer.response(405) }

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/file").read
          end
          refute_kind_of IOStreams::Errors::StorageError, error
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
          assert_kind_of IOStreams::Errors::PermissionDenied, error
        end

        it "raises PermissionDenied when the server returns 403 Forbidden" do
          start_server { |_path| TestHTTPServer.response(403) }
          path = IOStreams::Paths::HTTP.new("#{@server.base_url}/secret.csv")

          [-> { path.read }, -> { path.exist? }].each do |request|
            error = assert_raises(IOStreams::Errors::PermissionDenied, &request)

            assert_equal "#{@server.base_url}/secret.csv: Invalid response code: 403", error.message
          end
        end

        it "raises on an unsuccessful response code" do
          start_server { |_path| TestHTTPServer.response(500) }

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/file").read
          end
          assert_includes error.message, "Invalid response code: 500"
          assert_kind_of IOStreams::Errors::Unavailable, error
        end

        [429, 502, 503, 504].each do |status|
          it "raises Unavailable when the server responds with #{status}" do
            start_server { |_path| TestHTTPServer.response(status) }

            error = assert_raises IOStreams::Errors::Unavailable do
              IOStreams::Paths::HTTP.new("#{@server.base_url}/file").read
            end
            assert_instance_of IOStreams::Errors::CommunicationsFailure, error
          end
        end

        it "closes the connection before the block reads the file" do
          start_server { |_path| TestHTTPServer.response(200, body: body) }
          path     = IOStreams::Paths::HTTP.new("#{@server.base_url}/file")
          started  = Net::HTTP.method(:start)
          open     = false
          tracking = lambda do |*args, **options, &block|
            started.call(*args, **options) do |http|
              open = true
              block.call(http)
            ensure
              open = false
            end
          end

          was_open = Net::HTTP.stub(:start, tracking) { path.reader { |_io| open } }

          refute was_open
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

          it "answers allowed? on a frozen root within the allowed paths" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }
            IOStreams.add_allowed_path("#{@server.base_url}/files")
            root = IOStreams.path("#{@server.base_url}/files").freeze

            assert_predicate root, :allowed?
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

          it "does not follow a redirect to another port" do
            @other = TestHTTPServer.new { |_path| TestHTTPServer.response(201) }
            start_server { |_path| TestHTTPServer.response(307, headers: {"Location" => "#{@other.base_url}/file.txt"}) }

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect").write(body)
            end
            assert_includes error.message, "same scheme, host and port"
            assert_empty @other.requests
          end

          it "does not follow a redirect to another host" do
            start_server do |path|
              if path == "/redirect"
                TestHTTPServer.response(307, headers: {"Location" => "http://localhost:#{@server.port}/file.txt"})
              else
                TestHTTPServer.response(201)
              end
            end

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect").write(body)
            end
            assert_includes error.message, "same scheme, host and port"
            assert_equal 1, @server.requests.size
          end

          it "sends the headers and credentials across a same-origin redirect" do
            start_server do |path|
              if path == "/redirect"
                TestHTTPServer.response(307, headers: {"Location" => "/file.txt"})
              else
                TestHTTPServer.response(201)
              end
            end

            IOStreams::Paths::HTTP.new(
              "#{@server.base_url}/redirect",
              username: "jack", password: "secret", headers: {"X-Api-Key" => "key"}
            ).write(body)

            redirected = @server.requests.last[:headers]

            refute_nil redirected["authorization"]
            assert_equal "key", redirected["x-api-key"]
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

        describe "#exist?" do
          it "returns true when the file exists, using a head request" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }

            assert_predicate IOStreams.path("#{@server.base_url}/file.txt"), :exist?
            assert_equal "HEAD", @server.requests.first[:method]
          end

          it "returns false when the file is not found" do
            start_server { |_path| TestHTTPServer.response(404) }

            refute_predicate IOStreams.path("#{@server.base_url}/file.txt"), :exist?
          end

          it "returns false when the file is gone" do
            start_server { |_path| TestHTTPServer.response(410) }

            refute_predicate IOStreams.path("#{@server.base_url}/file.txt"), :exist?
          end

          it "raises when the server does not support head requests" do
            start_server { |_path| TestHTTPServer.response(405) }

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              IOStreams.path("#{@server.base_url}/file.txt").exist?
            end
            assert_includes error.message, "405"
          end

          it "raises when the server requires authorization" do
            start_server { |_path| TestHTTPServer.response(401) }

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              IOStreams.path("#{@server.base_url}/file.txt").exist?
            end
            assert_includes error.message, "Authorization Required"
          end

          it "sends the supplied headers and credentials" do
            start_server { |_path| TestHTTPServer.response(200) }

            IOStreams::Paths::HTTP.new(
              "#{@server.base_url}/file.txt", username: "jack", password: "secret", headers: {"X-Api-Key" => "key"}
            ).exist?

            headers = @server.requests.first[:headers]

            refute_nil headers["authorization"]
            assert_equal "key", headers["x-api-key"]
          end

          it "follows a redirect to another host, without the supplied headers" do
            @other = TestHTTPServer.new { |_path| TestHTTPServer.response(404) }
            start_server { |_path| TestHTTPServer.response(302, headers: {"Location" => "#{@other.base_url}/file.txt"}) }

            refute_predicate IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt", headers: {"X-Api-Key" => "key"}), :exist?

            redirected = @other.requests.first

            assert_equal "HEAD", redirected[:method]
            assert_nil redirected[:headers]["x-api-key"]
          end

          it "denies a url outside the allowed paths without contacting the server" do
            start_server { |_path| TestHTTPServer.response(200) }
            IOStreams.add_allowed_path("#{@server.base_url}/files")

            assert_raises IOStreams::Errors::AccessDenied do
              IOStreams.path("#{@server.base_url}/secret.csv").exist?
            end
            assert_empty @server.requests
          ensure
            IOStreams.instance_variable_set(:@allowed_paths, [].freeze)
          end
        end

        describe "#size" do
          it "returns the content length from a head request" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }

            assert_equal body.bytesize, IOStreams.path("#{@server.base_url}/file.txt").size

            request = @server.requests.first

            assert_equal "HEAD", request[:method]
            assert_equal "identity", request[:headers]["accept-encoding"]
          end

          it "raises NotFound when the file is not found" do
            start_server { |_path| TestHTTPServer.response(404) }

            assert_raises(IOStreams::Errors::NotFound) { IOStreams.path("#{@server.base_url}/file.txt").size }
          end

          it "returns nil when the server does not supply the size" do
            start_server { |_path| "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" }

            assert_nil IOStreams.path("#{@server.base_url}/file.txt").size
          end
        end

        describe "#size?" do
          it "returns nil for an empty or missing file" do
            start_server { |path| TestHTTPServer.response(path == "/empty.txt" ? 200 : 404, body: "") }

            assert_nil IOStreams.path("#{@server.base_url}/empty.txt").size?
            assert_nil IOStreams.path("#{@server.base_url}/missing.txt").size?
          end

          it "returns the size of a file" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }

            assert_equal body.bytesize, IOStreams.path("#{@server.base_url}/file.txt").size?
          end
        end

        describe "#file?" do
          it "is true when the file exists" do
            start_server { |path| TestHTTPServer.response(path == "/file.txt" ? 200 : 404, body: "") }

            assert_predicate IOStreams.path("#{@server.base_url}/file.txt"), :file?
            refute_predicate IOStreams.path("#{@server.base_url}/missing.txt"), :file?
            assert(@server.requests.all? { |request| request[:method] == "HEAD" })
          end
        end

        describe "#directory?" do
          it "is always false, without a request" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }

            refute_predicate IOStreams.path("#{@server.base_url}/files"), :directory?
            assert_empty @server.requests
          end
        end

        describe "#empty?" do
          it "is true when the file exists without any data" do
            start_server do |path|
              case path
              when "/empty.txt" then TestHTTPServer.response(200, body: "")
              when "/file.txt" then TestHTTPServer.response(200, body: body)
              else TestHTTPServer.response(404)
              end
            end

            assert_predicate IOStreams.path("#{@server.base_url}/empty.txt"), :empty?
            refute_predicate IOStreams.path("#{@server.base_url}/file.txt"), :empty?
            refute_predicate IOStreams.path("#{@server.base_url}/missing.txt"), :empty?
          end
        end

        describe "#delete" do
          it "deletes the file, returning the path" do
            start_server { |_path| TestHTTPServer.response(204) }
            path = IOStreams.path("#{@server.base_url}/file.txt")

            assert_same path, path.delete

            request = @server.requests.first

            assert_equal "DELETE", request[:method]
            assert_equal "/file.txt", request[:path]
          end

          it "does not raise when the file is not found" do
            start_server { |_path| TestHTTPServer.response(404) }
            path = IOStreams.path("#{@server.base_url}/file.txt")

            assert_same path, path.delete
          end

          it "does not raise when the file is gone" do
            start_server { |_path| TestHTTPServer.response(410) }
            path = IOStreams.path("#{@server.base_url}/file.txt")

            assert_same path, path.delete
          end

          it "raises on an unsuccessful response code" do
            start_server { |_path| TestHTTPServer.response(405) }

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              IOStreams.path("#{@server.base_url}/file.txt").delete
            end
            assert_includes error.message, "405"
          end

          it "follows a same-origin 307 redirect" do
            start_server do |path|
              if path == "/redirect"
                TestHTTPServer.response(307, headers: {"Location" => "/file.txt"})
              else
                TestHTTPServer.response(204)
              end
            end

            IOStreams.path("#{@server.base_url}/redirect").delete

            assert_equal(%w[DELETE DELETE], @server.requests.map { |request| request[:method] })
            assert_equal "/file.txt", @server.requests.last[:path]
          end

          it "does not follow a redirect to another host" do
            @other = TestHTTPServer.new { |_path| TestHTTPServer.response(204) }
            start_server { |_path| TestHTTPServer.response(307, headers: {"Location" => "#{@other.base_url}/file.txt"}) }

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              IOStreams.path("#{@server.base_url}/redirect").delete
            end
            assert_includes error.message, "same scheme, host and port"
            assert_empty @other.requests
          end

          it "does not follow a redirect that would change the request into a get" do
            start_server { |_path| TestHTTPServer.response(302, headers: {"Location" => "/file.txt"}) }

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              IOStreams.path("#{@server.base_url}/redirect").delete
            end
            assert_includes error.message, "Only a 307 or 308 redirect"
            assert_equal 1, @server.requests.size
          end
        end

        describe "#copy_from" do
          it "uploads without a head request" do
            start_server { |_path| TestHTTPServer.response(201) }

            IOStreams.path("#{@server.base_url}/file.txt").copy_from(StringIO.new(body))

            assert_equal(["PUT"], @server.requests.map { |request| request[:method] })
          end

          it "does not delete the file when the upload fails" do
            start_server { |_path| TestHTTPServer.response(500) }

            assert_raises IOStreams::Errors::CommunicationsFailure do
              IOStreams.path("#{@server.base_url}/file.txt").copy_from(StringIO.new(body))
            end
            assert_equal(["PUT"], @server.requests.map { |request| request[:method] })
          end
        end

        describe "#mkpath" do
          it "returns the path without contacting the server" do
            start_server { |_path| TestHTTPServer.response(200) }
            path = IOStreams.path("#{@server.base_url}/files/file.txt")

            assert_same path, path.mkpath
            assert_same path, path.mkdir
            assert_empty @server.requests
          end
        end

        describe "#move_to" do
          it "uploads a local file and then deletes it" do
            start_server { |_path| TestHTTPServer.response(201) }

            IOStreams.temp_file("iostreams_http", ".txt") do |source|
              source.write(body)
              target = IOStreams.path("#{@server.base_url}/files/file.txt")

              assert_same target, source.move_to(target)
              refute_predicate source, :exist?
            end
            request = @server.requests.first

            assert_equal(["PUT"], @server.requests.map { |r| r[:method] })
            assert_equal body, request[:body]
          end

          it "downloads the file and then deletes it" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }

            IOStreams.temp_file("iostreams_http", ".txt") do |target|
              IOStreams.path("#{@server.base_url}/file.txt").move_to(target)

              assert_equal body, target.read
            end
            assert_equal(%w[GET DELETE], @server.requests.map { |request| request[:method] })
          end
        end

        describe "redirects" do
          def redirect_to(location, status: 307)
            response             = Net::HTTPResponse::CODE_TO_OBJ[status.to_s].new("1.1", status.to_s, "Redirect")
            response["location"] = location
            response
          end

          it "does not follow a redirect from https to http" do
            path = IOStreams::Paths::HTTP.new("https://example.com/file")

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              path.send(:redirect_uri, URI.parse(path.url), redirect_to("http://example.com/file"), 1, Net::HTTP::Get)
            end
            assert_includes error.message, "from https to http"
          end

          it "follows a redirect from http to https when reading" do
            path    = IOStreams::Paths::HTTP.new("http://example.com/file")
            new_uri = path.send(:redirect_uri, URI.parse(path.url), redirect_to("https://example.com/file"), 1, Net::HTTP::Get)

            assert_equal "https://example.com/file", new_uri.to_s
          end

          it "does not follow a redirect from http to https when writing" do
            path = IOStreams::Paths::HTTP.new("http://example.com/file")

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              path.send(:redirect_uri, URI.parse(path.url), redirect_to("https://example.com/file"), 1, Net::HTTP::Put)
            end
            assert_includes error.message, "same scheme, host and port"
          end

          it "logs each redirect that is followed, without credentials or the query" do
            start_server do |path|
              if path.start_with?("/redirect")
                TestHTTPServer.response(302, headers: {"Location" => "/file?X-Amz-Signature=secret"})
              else
                TestHTTPServer.response(200, body: body)
              end
            end
            output   = StringIO.new
            original = IOStreams.logger
            IOStreams.logger = Logger.new(output, level: :info)

            url = "http://jack:secret@127.0.0.1:#{@server.port}/redirect?token=secret"
            IOStreams::Paths::HTTP.new(url).read

            assert_includes output.string, "Following HTTP 302 redirect from #{@server.base_url}/redirect to #{@server.base_url}/file"
            refute_includes output.string, "secret"
          ensure
            IOStreams.logger = original
          end
        end

        describe "headers:" do
          it "sends the supplied headers when reading" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }

            IOStreams::Paths::HTTP.new("#{@server.base_url}/file", headers: {"Authorization" => "Bearer token"}).read

            assert_equal "Bearer token", @server.requests.first[:headers]["authorization"]
          end

          it "does not send the supplied headers across a redirect to another host" do
            @other = TestHTTPServer.new { |_path| TestHTTPServer.response(200, body: body) }
            start_server { |_path| TestHTTPServer.response(302, headers: {"Location" => "#{@other.base_url}/file"}) }

            result = IOStreams::Paths::HTTP.new(
              "#{@server.base_url}/redirect",
              headers: {"X-Api-Key" => "key", "Cookie" => "session=1", "Accept" => "text/csv"}
            ).read

            assert_equal body, result
            assert_equal "key", @server.requests.first[:headers]["x-api-key"]

            redirected = @other.requests.first[:headers]

            assert_nil redirected["x-api-key"]
            assert_nil redirected["cookie"]
            refute_equal "text/csv", redirected["accept"]
          end

          it "sends the supplied headers across a same-origin redirect" do
            start_server do |path|
              if path == "/redirect"
                TestHTTPServer.response(302, headers: {"Location" => "/file"})
              else
                TestHTTPServer.response(200, body: body)
              end
            end

            IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect", headers: {"X-Api-Key" => "key"}).read

            assert(@server.requests.all? { |request| request[:headers]["x-api-key"] == "key" })
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
