# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../http_server"
require "socket"
require "base64"
require "csv"
require "logger"
require "open3"
require "openssl"
require "rbconfig"

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

        it "raises ArgumentError for a url without a host" do
          error = assert_raises(ArgumentError) { IOStreams.path("http:///a.csv") }

          assert_includes error.message, %(Invalid HTTP url "http:///a.csv": it must name a host, such as 'https://example.org/a.csv')
        end

        it "raises ArgumentError for a url that cannot be parsed, without its password or query" do
          {
            "https://jack:TOP SECRET@example.com/a.csv"    => "https://[FILTERED]@example.com/a.csv",
            "https://example.com/my file.csv?token=SECRET" => "https://example.com/my file.csv"
          }.each_pair do |url, name|
            error = assert_raises(ArgumentError) { IOStreams.path(url) }

            assert_includes error.message, "Invalid url #{name.inspect}: it cannot be parsed"
            refute_includes error.full_message, "SECRET"
            assert_nil error.cause
          end
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

      describe "comparison" do
        it "is equal to another spelling of the url" do
          path = IOStreams.path("https://example.org/data/~a.csv?q=~1")
          urls = %w[
            https://EXAMPLE.org/data/~a.csv?q=~1 HTTPS://example.org/data/~a.csv?q=~1
            https://example.org:443/data/~a.csv?q=~1 https://example.org:/data/~a.csv?q=~1
            https://example.org/data/%7Ea.csv?q=%7E1 https://example.org/data/%7ea%2Ecsv?q=%7e1
            https://jack:secret@example.org/data/~a.csv?q=~1 https://example.org/data/~a.csv?q=~1#part
          ]

          urls.each { |url| assert_equal_paths path, IOStreams.path(url), url }
          assert_equal_paths path, IOStreams.path("https://example.org/data/~a.csv", parameters: {q: "~1"}, username: "jack")
        end

        it "is equal to the root of the host, whether its url ends with /" do
          assert_equal_paths IOStreams.path("http://example.org"), IOStreams.path("http://example.org:80/")
        end

        it "compares a percent-encoded character that is not the same as the character, whatever the case of its digits" do
          path = IOStreams.path("https://example.org/a%2fb%2bc.csv")

          assert_equal_paths path, IOStreams.path("https://example.org/a%2Fb%2Bc.csv")
          refute_equal_paths path, IOStreams.path("https://example.org/a/b+c.csv")
          assert_equal_paths IOStreams.path("https://example.org/caf%c3%a9.csv"), IOStreams.path("https://example.org/caf%C3%A9.csv")
        end

        it "compares the scheme and host without their case, and the port, path and query as they are" do
          path = IOStreams.path("https://example.org/data/a.csv?x=1")
          urls = %w[
            http://example.org/data/a.csv?x=1 https://example.org:8443/data/a.csv?x=1 https://example.org:80/data/a.csv?x=1
            https://example.com/data/a.csv?x=1 https://example.org/data/A.csv?x=1 https://example.org/data/a.csv?X=1
            https://example.org/data/a.csv https://example.org/data/a.csv?x=1& https://example.org/data/./a.csv?x=1
            https://example.org//data/a.csv?x=1 https://example.org/data/a.csv/?x=1 https://example.org/data%2Fa.csv?x=1
          ]

          urls.each { |url| refute_equal_paths path, IOStreams.path(url), url }
          refute_equal_paths IOStreams.path("https://example.org/a.csv?"), IOStreams.path("https://example.org/a.csv")
          refute_equal_paths IOStreams.path("http://[fe80::1]:8080/a.csv"), IOStreams.path("http://[fe80::1:8080]/a.csv")
        end

        it "sorts by the url that it compares" do
          urls  = %w[https://B.org/a.csv http://b.org/a.csv https://a.org:8443/a.csv HTTPS://A.org:443/b.csv https://jack@a.org/a.csv]
          paths = urls.map { |url| IOStreams.path(url) }

          assert_equal %w[http://b.org/a.csv https://jack@a.org/a.csv HTTPS://A.org:443/b.csv https://a.org:8443/a.csv https://B.org/a.csv],
                       paths.sort.map(&:to_s)
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
          refute_respond_to path, :children
          assert_respond_to path, :exist?
          assert_respond_to path, :size?
          assert_respond_to path, :move_to
          assert_respond_to path, :read
        end
      end

      describe "#join" do
        it "encodes every % in a joined name, which is a name rather than part of a url" do
          %w[100%.csv 100%41.csv my%20file.csv].each do |name|
            path = IOStreams::Paths::HTTP.new("https://example.com/files").join(name)

            assert_equal "https://example.com/files/#{name.gsub('%', '%25')}", path.to_s
            assert_equal name, path.basename
            assert_equal path.path, IOStreams.path(path.to_s).path
          end
        end

        it "encodes a space in a joined name" do
          path = IOStreams::Paths::HTTP.new("https://example.com/files").join("my file.csv")

          assert_equal "https://example.com/files/my%20file.csv", path.to_s
        end
      end

      it "does not support streams" do
        assert_raises ArgumentError do
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

        describe "the encoding of the response" do
          let(:csv) { "a,b\n1,2\n" }
          let(:gzipped) { Zlib.gzip(csv) }

          # Returns [String] the url of the file on the server.
          def data_url(name = "data.csv")
            "#{@server.base_url}/#{name}"
          end

          # Returns [Array<String>] the Accept-Encoding of each request that the server received.
          def accept_encodings(server = @server)
            server.requests.map { |request| request[:headers]["accept-encoding"] }
          end

          # A server that serves a .gz file with `Content-Encoding: gzip` whenever the client accepts it, as many do.
          def start_gzip_server
            start_server do |_path, request|
              gzip = request[:headers]["accept-encoding"].to_s.include?("gzip")
              TestHTTPServer.response(200, body: gzipped, headers: gzip ? {"Content-Encoding" => "gzip"} : {})
            end
          end

          # A server that compresses the body while it sends it when the request accepts gzip, as nginx, Apache and
          # CDNs do for text.
          def start_compressing_server(data = csv)
            start_server do |_path, request|
              if request[:headers]["accept-encoding"].to_s.include?("gzip")
                TestHTTPServer.response(200, body: Zlib.gzip(data), headers: {"Content-Encoding" => "gzip"}, chunked: true)
              else
                TestHTTPServer.response(200, body: data)
              end
            end
          end

          # A server that sends the body with the Content-Encoding that is stored with it, whatever the request
          # accepts, as S3 does, or no Content-Encoding when it is nil.
          def start_labeling_server(data, content_encoding)
            headers = content_encoding.nil? ? {} : {"Content-Encoding" => content_encoding}
            start_server { |_path| TestHTTPServer.response(200, body: data, headers: headers) }
          end

          it "asks for gzip when the file is read through streams that neither compress nor encrypt it" do
            start_server { |_path| TestHTTPServer.response(404) }
            paths = [
              IOStreams.path("#{@server.base_url}/data.csv"),
              IOStreams.path("#{@server.base_url}/data.json"),
              IOStreams.path("#{@server.base_url}/data.parquet"),
              IOStreams.path("#{@server.base_url}/download"),
              IOStreams.path("#{@server.base_url}/legacy.csv").encoding("Windows-1252:UTF-8")
            ]

            paths.each { |path| assert_raises(IOStreams::Errors::NotFound) { path.read } }
            assert_equal ["gzip"] * paths.size, accept_encodings
          end

          it "asks for the file as it is stored when it is compressed or encrypted, read raw, or copied as it is" do
            start_server { |_path| TestHTTPServer.response(404) }
            paths = %w[data.csv.gz data.csv.bz2 data.csv.zst data.zip data.xlsx data.csv.pgp data.csv.enc].map do |name|
              IOStreams.path("#{@server.base_url}/#{name}")
            end
            paths << IOStreams.path("#{@server.base_url}/download").stream(:gz)
            paths << IOStreams.path("#{@server.base_url}/data.csv").raw

            paths.each { |path| assert_raises(IOStreams::Errors::NotFound) { path.read } }
            IOStreams.temp_file("iostreams_http_target", ".csv") do |target|
              assert_raises(IOStreams::Errors::NotFound) do
                IOStreams.path("#{@server.base_url}/data.csv").copy_to(target, convert: false)
              end
            end
            assert_equal ["identity"] * (paths.size + 1), accept_encodings
          end

          it "asks for gzip with the deprecated stream(:none), as v2.1 did, unlike #raw" do
            start_server { |_path| TestHTTPServer.response(404) }
            path = assert_deprecated(/stream\(:none\)/) { IOStreams.path("#{@server.base_url}/data.csv.gz").stream(:none) }

            assert_raises(IOStreams::Errors::NotFound) { path.read }
            assert_equal ["gzip"], accept_encodings
          end

          it "reads a file that the server compresses while it sends it" do
            start_compressing_server
            records = []

            assert_equal csv, IOStreams.path(data_url).read
            IOStreams.path(data_url).each(:hash) { |record| records << record }

            assert_equal [{"a" => "1", "b" => "2"}], records
            assert_equal %w[gzip gzip], accept_encodings
          end

          it "decompresses a body sent with the Content-Encoding gzip or x-gzip, in any case" do
            %w[gzip x-gzip GZIP X-Gzip].each do |content_encoding|
              start_labeling_server(gzipped, content_encoding)

              assert_equal csv, IOStreams.path(data_url).read, content_encoding
              @server.shutdown
            end
          end

          it "reads a file stored compressed, with the Content-Encoding gzip, as its content, and #raw as it is stored" do
            start_labeling_server(gzipped, "gzip")

            assert_equal csv, IOStreams.path(data_url).read
            assert_equal gzipped, IOStreams.path(data_url).raw.read.b
            assert_equal gzipped.bytesize, IOStreams.path(data_url).size
            assert_equal %w[gzip identity identity], accept_encodings
          end

          it "decompresses a .gz file that the server sends with its Content-Encoding once, with its gzip stream" do
            %w[gzip x-gzip].each do |content_encoding|
              start_labeling_server(gzipped, content_encoding)

              assert_equal csv, IOStreams.path(data_url("data.csv.gz")).read
              assert_equal gzipped, IOStreams.path(data_url("data.csv.gz")).raw.read.b
              assert_equal %w[identity identity], accept_encodings
              @server.shutdown
            end
          end

          it "requests the file as it is stored" do
            start_gzip_server
            url = data_url("data.csv.gz")

            assert_equal gzipped, IOStreams.path(url).raw.read.b
            assert_equal csv, IOStreams.path(url).read
            assert_equal %w[identity identity], accept_encodings
          end

          it "reads a body that is not encoded as it is sent" do
            [nil, "", "identity", "Identity", "none", "NONE"].each do |content_encoding|
              start_labeling_server(csv, content_encoding)

              assert_equal csv, IOStreams.path(data_url).read, content_encoding.inspect
              @server.shutdown
            end
          end

          it "reads an empty body as empty, whatever its Content-Encoding" do
            start_labeling_server("", "gzip")

            assert_equal "", IOStreams.path(data_url).read
          end

          it "decompresses every member of a body of several gzip members" do
            random = Random.new(42)
            # Larger than a read of the decompressor, and than a chunk of the body.
            lines  = Array.new(20_000) { |i| "#{i},#{random.rand(10**12)}\n" }
            start_labeling_server(lines.each_slice(5_000).map { |slice| Zlib.gzip(slice.join) }.join, "gzip")

            assert_equal lines.join, IOStreams.path(data_url).read
          end

          it "decompresses every member of a body of many small gzip members" do
            lines = Array.new(2_000) { |i| "#{format('%04d', i)},#{'x' * 250}\n" }
            start_labeling_server(lines.map { |line| Zlib.gzip(line) }.join, "gzip")

            assert_equal lines.join, IOStreams.path(data_url).read
          end

          it "raises before the block is called for a Content-Encoding that it cannot decode" do
            ["br", "zstd", "deflate", "compress", "gzip, gzip", "utf-8", "aws-chunked"].each do |content_encoding|
              start_labeling_server(csv, content_encoding)
              called = false

              error = assert_raises(IOStreams::Errors::CommunicationsFailure) do
                IOStreams.path("#{data_url}?token=SECRET").reader { |_io| called = true }
              end
              refute called
              assert_equal "Cannot decode the Content-Encoding #{content_encoding.inspect} of #{data_url}. To read the body " \
                           "as it is sent, supply headers: {\"Accept-Encoding\" => \"identity\"}", error.message
              refute_kind_of IOStreams::Errors::StorageError, error
              @server.shutdown
            end
          end

          it "raises for a gzip body that is truncated or corrupt, naming the url, with the failure as its cause" do
            truncated = gzipped.byteslice(0, gzipped.bytesize - 4)
            bad_crc   = gzipped.b.tap { |data| data.setbyte(-8, data.getbyte(-8) ^ 0xff) }
            # The failure of zlib for each body, which on JRuby can be an IOError, or Errno::EPIPE for one that ends early.
            [
              [truncated, Zlib::GzipFile::NoFooter, IOError],
              [gzipped.byteslice(0, 12), Zlib::GzipFile::Error, Errno::EPIPE],
              [bad_crc, Zlib::GzipFile::CRCError, IOError],
              ["#{gzipped}trailing garbage", Zlib::GzipFile::Error, Zlib::GzipFile::Error],
              ["not gzip", Zlib::GzipFile::Error, Zlib::GzipFile::Error]
            ].each do |data, cause, jruby_cause|
              start_labeling_server(data, "gzip")

              error = assert_raises(IOStreams::Errors::CommunicationsFailure) { IOStreams.path("#{data_url}?token=SECRET").read }
              assert_instance_of defined?(JRuby) ? jruby_cause : cause, error.cause
              assert_equal "Cannot decode the Content-Encoding \"gzip\" of #{data_url}: #{error.cause.message}", error.message
              refute_kind_of IOStreams::Errors::StorageError, error
              @server.shutdown
            end
          end

          it "raises the failure to decompress a body from within the block, once it has read what came before it" do
            data = csv * 10_000
            start_labeling_server(Zlib.gzip(data).byteslice(0..-5), "gzip")
            read = +""

            assert_raises(IOStreams::Errors::CommunicationsFailure) do
              IOStreams.path(data_url).reader { |io| read << io.read(10) << io.read }
            end
            assert_equal data.byteslice(0, 10), read
          end

          it "does not convert a Zlib::Error that the block raises" do
            start_labeling_server(gzipped, "gzip")

            error = assert_raises(Zlib::DataError) { IOStreams.path(data_url).reader { |_io| raise(Zlib::DataError, "block failed") } }
            assert_equal "block failed", error.message
          end

          it "limits the size of the body once decompressed to the maximum file size" do
            start_labeling_server(Zlib.gzip("\0" * 10_000_000), "gzip")
            path = IOStreams.path(data_url, maximum_file_size: 1_000_000)
            read = 0

            error = assert_raises(IOStreams::Errors::CommunicationsFailure) do
              path.reader { |io| read += io.read(65_536).bytesize while read < 2_000_000 }
            end
            assert_equal "Exceeded maximum allowed download size of 1000000 bytes once decompressed", error.message
            assert_operator read, :>, 0
            assert_operator read, :<=, 1_000_000
          end

          it "limits the bytes received to the maximum file size, also when they decompress to nothing" do
            start_labeling_server(Zlib.gzip("") * 6_000, "gzip")

            error = assert_raises(IOStreams::Errors::CommunicationsFailure) do
              IOStreams.path(data_url, maximum_file_size: 100_000).read
            end
            assert_equal "Exceeded maximum allowed download size of 100000 bytes", error.message
          end

          it "reads a body whose size once decompressed is the maximum file size" do
            data = csv * 1_000
            start_labeling_server(Zlib.gzip(data), "gzip")

            assert_equal data, IOStreams.path(data_url, maximum_file_size: data.bytesize).read
          end

          it "copies a file that the server compresses while it sends it, and copies it as it is stored without conversion" do
            start_compressing_server

            IOStreams.temp_file("iostreams_http_target", ".csv") do |target|
              IOStreams.path(data_url).copy_to(target)

              assert_equal csv, target.read
            end
            IOStreams.temp_file("iostreams_http_target", ".csv") do |target|
              IOStreams.path(data_url).copy_to(target, convert: false)

              assert_equal csv, target.read
            end
            assert_equal %w[gzip identity], accept_encodings
          end

          it "accepts the encodings supplied with headers:, and reads the body as it is sent" do
            start_gzip_server
            path = IOStreams.path("#{@server.base_url}/data.csv", headers: {"Accept-Encoding" => "gzip"})

            assert_equal gzipped, IOStreams.path(path).raw.read.b
            assert_equal gzipped, IOStreams.path(path).read.b
            assert_equal csv, IOStreams.path(path).stream(:gz).read
            assert_equal %w[gzip gzip gzip], accept_encodings
          end

          it "reads the body as it is sent, whatever its Content-Encoding, with headers: that accept only identity" do
            start_labeling_server(csv, "br")
            path = IOStreams.path(data_url, headers: {"accept-encoding" => "identity"})

            assert_equal csv, path.read
            assert_equal ["identity"], accept_encodings
          end

          it "asks for the file as it is stored with a Range supplied with headers:, since a range of a compressed body cannot be decompressed" do
            start_server do |_path, request|
              if request[:headers]["accept-encoding"].to_s.include?("gzip")
                # As nginx does, which compresses the whole file, rather than sending the range.
                TestHTTPServer.response(200, body: Zlib.gzip(csv), headers: {"Content-Encoding" => "gzip"})
              else
                TestHTTPServer.response(206, body: csv.byteslice(0, 4), headers: {"Content-Range" => "bytes 0-3/#{csv.bytesize}"})
              end
            end

            assert_equal "a,b\n", IOStreams.path(data_url, headers: {"Range" => "bytes=0-3"}).read
            assert_equal ["identity"], accept_encodings
          end

          it "asks for gzip after a redirect to another host, and decompresses its response" do
            @other = TestHTTPServer.new do |_path|
              TestHTTPServer.response(200, body: gzipped, headers: {"Content-Encoding" => "gzip"})
            end
            start_server { |_path| TestHTTPServer.response(302, headers: {"Location" => "#{@other.base_url}/data.csv"}) }

            assert_equal csv, IOStreams.path(data_url).read
            assert_equal ["gzip"], accept_encodings
            assert_equal ["gzip"], accept_encodings(@other)
          end
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

        it "raises NotFound with the display name of the path, without its credentials, query or parameters" do
          start_server { |_path| TestHTTPServer.response(404) }
          url = "http://jack:TOP-SECRET@127.0.0.1:#{@server.port}/missing.csv?token=SECRET"

          error = assert_raises(IOStreams::Errors::NotFound) do
            IOStreams::Paths::HTTP.new(url, parameters: {api_key: "PARAMETER-SECRET"}).read
          end
          assert_equal "http://127.0.0.1:#{@server.port}/missing.csv", error.display_name
          refute_includes error.message, "SECRET"
          refute_includes error.message, "jack"
        end

        it "does not include credentials or the query in the message of a redirect that is not followed" do
          start_server do |path|
            case path
            when %r{\A/ftp} then TestHTTPServer.response(302, headers: {"Location" => "ftp://127.0.0.1/x?token=LOCATION-SECRET"})
            when %r{\A/nowhere} then TestHTTPServer.response(302)
            else TestHTTPServer.response(301, headers: {"Location" => "/other?token=LOCATION-SECRET"})
            end
          end
          base = "http://jack:TOP-SECRET@127.0.0.1:#{@server.port}"

          [
            -> { IOStreams.path("#{base}/ftp?token=SECRET").read },
            -> { IOStreams.path("#{base}/nowhere?token=SECRET").read },
            -> { IOStreams.path("#{base}/upload?token=SECRET").write("data") }
          ].each do |request|
            error = assert_raises(IOStreams::Errors::CommunicationsFailure, &request)

            refute_includes error.message, "SECRET"
            refute_includes error.message, "jack"
          end
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

        describe "reading as the block reads" do
          # Larger than a chunk, and than the socket buffers, so that the server is still sending it when the block
          # stops reading.
          let(:large) { "0123456789" * 200_000 }

          # Returns the result of the block, which is called with a lambda that returns the number of open connections.
          def tracking_connections
            started  = Net::HTTP.method(:start)
            open     = 0
            tracking = lambda do |*args, **options, &block|
              started.call(*args, **options) do |http|
                open += 1
                block.call(http)
              ensure
                open -= 1
              end
            end
            Net::HTTP.stub(:start, tracking) { yield(-> { open }) }
          end

          it "reads lines like an IO, as the response is read" do
            start_server { |_path| TestHTTPServer.response(200, body: "a,b\n1,2\n") }
            path = IOStreams::Paths::HTTP.new("#{@server.base_url}/file")

            rows = path.reader { |io| CSV.new(io).to_a }

            assert_equal [%w[a b], %w[1 2]], rows
          end

          it "keeps the connection open while the block reads, and closes it once the block returns" do
            start_server { |_path| TestHTTPServer.response(200, body: large) }
            path = IOStreams::Paths::HTTP.new("#{@server.base_url}/file")

            tracking_connections do |open|
              open_while_reading = path.reader { |io| io.read(10) && open.call }

              assert_equal 1, open_while_reading
              assert_equal 0, open.call
            end
          end

          it "closes the connection when the block raises" do
            start_server { |_path| TestHTTPServer.response(200, body: large) }
            path = IOStreams::Paths::HTTP.new("#{@server.base_url}/file")

            tracking_connections do |open|
              assert_raises(ArgumentError) { path.reader { |io| io.read(10) && raise(ArgumentError, "block failed") } }
              assert_equal 0, open.call
            end
          end

          describe "a body that is decompressed as it is read" do
            # Not compressible, so that the server is still sending it when the block stops reading.
            let(:random) { Random.new(42).bytes(2_000_000) }

            before do
              compressed = Zlib.gzip(random)
              start_server { |_path| TestHTTPServer.response(200, body: compressed, headers: {"Content-Encoding" => "gzip"}) }
            end

            it "closes the connection, and the decompressor, once the block returns" do
              path = IOStreams::Paths::HTTP.new("#{@server.base_url}/file")
              stream = nil

              tracking_connections do |open|
                read, open_while_reading = path.reader do |io|
                  stream = io
                  [io.read(10), open.call]
                end

                assert_equal random.byteslice(0, 10), read
                assert_equal 1, open_while_reading
                assert_equal 0, open.call
                assert_predicate stream, :closed?
              end
            end

            it "closes the connection, and the decompressor, when the block raises" do
              path   = IOStreams::Paths::HTTP.new("#{@server.base_url}/file")
              stream = nil
              read   = nil

              tracking_connections do |open|
                assert_raises(ArgumentError) do
                  path.reader do |io|
                    stream = io
                    read   = io.read(10)
                    raise(ArgumentError, "block failed")
                  end
                end
                assert_equal random.byteslice(0, 10), read
                assert_equal 0, open.call
                assert_predicate stream, :closed?
              end
            end

            it "closes the connection, and the decompressor, when the thread reading is killed" do
              path    = IOStreams::Paths::HTTP.new("#{@server.base_url}/file")
              stream  = nil
              reading = Queue.new

              tracking_connections do |open|
                thread = Thread.new do
                  path.reader do |io|
                    stream = io
                    reading << [io.read(10), open.call]
                    sleep
                  end
                end

                assert_equal [random.byteslice(0, 10), 1], reading.pop
                thread.kill.join

                assert_equal 0, open.call
                assert_predicate stream, :closed?
              end
            end
          end

          it "closes the connection that redirected before the block reads" do
            start_server do |path|
              path == "/redirect" ? TestHTTPServer.response(302, headers: {"Location" => "/file"}) : TestHTTPServer.response(200, body: large)
            end
            path = IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect")

            tracking_connections do |open|
              open_while_reading = path.reader { |io| io.read(10) && open.call }

              assert_equal 1, open_while_reading
            end
          end

          it "lets a Fiber scheduler, such as Async, run its other Fibers while it waits for the body" do
            skip "The async gem is only installed on MRI" if defined?(JRuby)
            require "async"
            start_server do |_path|
              lambda do |client|
                client.write("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n")
                4.times do |i|
                  sleep(0.05)
                  client.write(i.to_s)
                end
              end
            end
            path  = IOStreams::Paths::HTTP.new("#{@server.base_url}/file")
            ticks = 0
            data  = nil

            Sync do |task|
              ticker = task.async do
                loop do
                  ticks += 1
                  sleep(0.01)
                end
              end
              data = path.read
              ticker.stop
            end

            assert_equal "0123", data
            # Blocking the scheduler would allow only the first tick.
            assert_operator ticks, :>, 5
          end

          it "makes the request before the block is called, so that a missing file raises before the block runs" do
            start_server { |_path| TestHTTPServer.response(404) }
            called = false

            assert_raises(IOStreams::Errors::NotFound) do
              IOStreams::Paths::HTTP.new("#{@server.base_url}/missing.csv").reader { |_io| called = true }
            end
            refute called
          end

          it "does not change the target of #copy_from when the source is missing" do
            start_server { |_path| TestHTTPServer.response(404) }

            IOStreams.temp_file("iostreams_http_target", ".csv") do |target|
              target.write("existing")

              assert_raises(IOStreams::Errors::NotFound) { target.copy_from("#{@server.base_url}/missing.csv") }
              assert_equal "existing", target.read
            end
          end

          describe "when the connection closes part way through the body" do
            let(:chunked) { "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\na\r\n0123456789\r\na\r\nabc" }
            let(:url) { "#{@server.base_url}/data.csv" }

            it "raises Unavailable, rather than EOFError, which would end the body early" do
              start_server { |_path| chunked }

              error = assert_raises(IOStreams::Errors::CommunicationsFailure) { IOStreams.path(url).read }
              assert_kind_of IOStreams::Errors::Unavailable, error
              assert_equal "#{url}: The connection closed before the whole body was received", error.message
            end

            it "raises when the body is shorter than its Content-Length" do
              start_server { |_path| "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n0123456789" }

              assert_raises(IOStreams::Errors::Unavailable) { IOStreams.path(url).read }
            end

            it "raises from #copy_to, rather than copying part of the file" do
              start_server { |_path| chunked }

              IOStreams.temp_file("iostreams_http_target", ".csv") do |target|
                assert_raises(IOStreams::Errors::Unavailable) { IOStreams.path(url).copy_to(target, convert: false) }
                refute_predicate target, :exist?
              end
            end

            it "does not delete the source after #move_to fails" do
              start_server { |_path| chunked }

              IOStreams.temp_file("iostreams_http_target", ".csv") do |target|
                assert_raises(IOStreams::Errors::Unavailable) { IOStreams.path(url).move_to(target) }
                methods = @server.requests.map { |request| request[:method] }

                assert_equal ["GET"], methods
              end
            end

            it "raises its failure again on every later read" do
              start_server { |_path| chunked }

              IOStreams.path(url).raw.reader do |io|
                assert_equal "0123456789abc", io.read(13)
                first = assert_raises(IOStreams::Errors::Unavailable) { io.read(1) }
                assert_same first, assert_raises(IOStreams::Errors::Unavailable) { io.read(1) }
                assert_same first, assert_raises(IOStreams::Errors::Unavailable) { io.eof? }
              end
            end

            it "does not send the request again once part of the body has been received" do
              received = Queue.new
              start_server do |_path|
                if @server.requests.size == 1
                  TestHTTPServer.reset_after do |client|
                    client.write("HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\n0123456789")
                    received.pop(timeout: 5)
                  end
                else
                  TestHTTPServer.response(200, body: "0123456789abcdefghij")
                end
              end
              read = +""

              assert_raises(IOStreams::Errors::Unavailable) do
                IOStreams.path(url).raw.reader do |io|
                  read << io.read(10)
                  received << true
                  read << io.read
                end
              end
              assert_equal "0123456789", read
              assert_equal 1, @server.requests.size
            end
          end

          it "does not tag a failure of the block as a failure of the request" do
            start_server { |_path| TestHTTPServer.response(200, body: large) }
            path = IOStreams::Paths::HTTP.new("#{@server.base_url}/file")

            error = assert_raises(Errno::ECONNRESET) { path.reader { |io| io.read(10) && raise(Errno::ECONNRESET) } }
            refute_kind_of IOStreams::Errors::Unavailable, error
          end

          it "raises within the block when the body exceeds the maximum file size" do
            start_server { |_path| TestHTTPServer.response(200, body: large) }
            path = IOStreams::Paths::HTTP.new("#{@server.base_url}/file", maximum_file_size: 100_000)
            read = nil

            assert_raises(IOStreams::Errors::CommunicationsFailure) do
              path.reader do |io|
                read = io.read(10)
                io.read
              end
            end
            assert_equal "0123456789", read
          end

          it "reads a zip file, which is copied into a temp file" do
            zip = StringIO.new
            IOStreams.stream(zip).file_name("data.zip").option(:zip, entry_file_name: "data.csv").write(body)
            start_server { |_path| TestHTTPServer.response(200, body: zip.string) }

            assert_equal body, IOStreams::Paths::HTTP.new("#{@server.base_url}/data.zip").read
          end
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

        it "raises for a redirect to a location that is not a url, without the location" do
          start_server { |_path| TestHTTPServer.response(302, headers: {"Location" => "http://exa mple.com/a.csv?token=secret"}) }

          error = assert_raises IOStreams::Errors::CommunicationsFailure do
            IOStreams::Paths::HTTP.new("#{@server.base_url}/redirect").read
          end
          assert_equal "Redirect to a location that is not a url: #{@server.base_url}/redirect", error.message
          assert_nil error.cause
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

        it "allows a host in the allow list whatever its case, since host names are not case-sensitive" do
          connected = Class.new(StandardError)

          Net::HTTP.stub(:start, ->(*) { raise connected }) do
            assert_raises(connected) { IOStreams::Paths::HTTP.new("https://Example.COM/file", allow_hosts: ["example.com"]).read }
            assert_raises(connected) { IOStreams::Paths::HTTP.new("https://example.com/file", allow_hosts: "EXAMPLE.com").read }
          end
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

          it "uploads what was written when the block leaves early, as a local file keeps it" do
            start_server { |_path| TestHTTPServer.response(200) }

            IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt").writer do |io|
              io.write(body)
              break
            end

            assert_equal body, @server.requests.first[:body]
          end

          it "uploads nothing when the block raises" do
            start_server { |_path| TestHTTPServer.response(200) }

            assert_raises(RuntimeError) do
              IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt").writer do |io|
                io.write(body)
                raise "boom"
              end
            end

            assert_empty @server.requests
          end

          it "uploads nothing when the thread writing it is killed" do
            start_server { |_path| TestHTTPServer.response(200) }
            started = Queue.new
            thread  = Thread.new do
              IOStreams::Paths::HTTP.new("#{@server.base_url}/file.txt").writer do |io|
                io.write(body)
                started << true
                sleep
              end
            end
            started.pop
            thread.kill.join

            assert_empty @server.requests
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

        describe "#mtime" do
          it "returns the Last-Modified time from a head request" do
            modified = Time.utc(2026, 10, 8, 12, 30, 0)
            start_server do |_path|
              "HTTP/1.1 200 OK\r\nLast-Modified: #{modified.httpdate}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            end

            assert_equal modified, IOStreams.path("#{@server.base_url}/file.txt").mtime
            assert_equal "HEAD", @server.requests.first[:method]
          end

          it "returns the time in a process that has only required iostreams" do
            start_server do |_path|
              "HTTP/1.1 200 OK\r\nLast-Modified: Wed, 21 Oct 2015 07:28:00 GMT\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            end
            # The test helper requires `time`, which defines Time.httpdate, so the time is read in a new process.
            script = %(require "iostreams"; print IOStreams.path("#{@server.base_url}/file.txt").mtime.to_i)
            output, = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)

            assert_equal Time.utc(2015, 10, 21, 7, 28, 0).to_i.to_s, output
          end

          it "returns nil when the server does not supply it" do
            start_server { |_path| "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }

            assert_nil IOStreams.path("#{@server.base_url}/file.txt").mtime
          end

          it "returns nil, and logs a warning, when the Last-Modified header is not a time" do
            start_server { |_path| "HTTP/1.1 200 OK\r\nLast-Modified: yesterday\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
            output   = StringIO.new
            original = IOStreams.logger
            IOStreams.logger = Logger.new(output, level: :warn)
            path = IOStreams.path("#{@server.base_url}/file.txt?token=SECRET")

            assert_nil path.mtime
            assert_includes output.string, "Ignoring the Last-Modified header of #{@server.base_url}/file.txt, which is not a time: \"yesterday\""
            refute_includes output.string, "SECRET"
          ensure
            IOStreams.logger = original
          end

          it "raises NotFound when the file is not found" do
            start_server { |_path| TestHTTPServer.response(404) }

            assert_raises(IOStreams::Errors::NotFound) { IOStreams.path("#{@server.base_url}/file.txt").mtime }
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

          it "raises ArgumentError for a target that is the same url, by any spelling, without a request" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }
            source  = IOStreams.path("http://localhost:#{@server.port}/files/file.txt")
            targets = [
              source, source.to_s, "http://LOCALHOST:#{@server.port}/files/./a/../file.txt",
              "http://localhost:#{@server.port}/files/file%2Etxt", "http://localhost:#{@server.port}/files%2Ffile.txt",
              "http://localhost:#{@server.port}/files/file.txt/"
            ]

            targets.each do |target|
              error = assert_raises(ArgumentError, target.to_s) { source.move_to(target) }

              assert_includes error.message, "Cannot move #{source.display_name} onto itself"
            end
            assert_empty @server.requests
          end

          it "raises ArgumentError for a target with another spelling of the same query, without a request" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }
            source = IOStreams.path("http://localhost:#{@server.port}/file.txt?v=~1")

            error = assert_raises(ArgumentError) { source.move_to("http://localhost:#{@server.port}/file.txt?v=%7e1") }

            assert_includes error.message, "Cannot move #{source.display_name} onto itself"
            assert_empty @server.requests
          end

          it "moves to the same path with another query, which can be another file" do
            start_server { |_path| TestHTTPServer.response(200, body: body) }

            IOStreams.path("#{@server.base_url}/file.txt?version=1").move_to("#{@server.base_url}/file.txt?version=2")

            assert_equal(%w[GET PUT DELETE], @server.requests.map { |request| request[:method] })
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

          it "does not include credentials or the query of either url in the message" do
            path     = IOStreams::Paths::HTTP.new("https://jack:TOP-SECRET@example.com/file?token=SECRET")
            redirect = redirect_to("http://example.com/file?token=LOCATION-SECRET")

            error = assert_raises IOStreams::Errors::CommunicationsFailure do
              path.send(:redirect_uri, URI.parse(path.url), redirect, 1, Net::HTTP::Get)
            end
            assert_equal "Redirect from https to http is not followed: https://example.com/file to http://example.com/file",
                         error.message
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

          it "sends an Accept-Encoding supplied with headers: across a redirect to another host, which holds no credential" do
            @other = TestHTTPServer.new { |_path| TestHTTPServer.response(200, body: body, headers: {"Content-Encoding" => "br"}) }
            start_server { |_path| TestHTTPServer.response(302, headers: {"Location" => "#{@other.base_url}/file"}) }

            %w[identity gzip].each do |accept_encoding|
              path = IOStreams::Paths::HTTP.new(
                "#{@server.base_url}/redirect", headers: {"Accept-Encoding" => accept_encoding, "X-Api-Key" => "key"}
              )

              assert_equal body, path.read
            end
            assert_equal(%w[identity gzip], @other.requests.map { |request| request[:headers]["accept-encoding"] })
            assert(@other.requests.none? { |request| request[:headers]["x-api-key"] })
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
