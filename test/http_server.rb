require "socket"
require "openssl"

# Minimal HTTP server used to exercise redirect, credential, allow-list,
# download-size and upload handling without depending on an external service.
#
# With `tls: true` it serves HTTPS with a self-signed certificate, see `.certificate`.
class TestHTTPServer
  attr_reader :port, :requests

  def initialize(tls: false, &handler)
    @handler  = handler
    @requests = []
    @tls      = tls
    tcp       = TCPServer.new("127.0.0.1", 0)
    @port     = tcp.addr[1]
    @server   = tls ? OpenSSL::SSL::SSLServer.new(tcp, ssl_context) : tcp
    @thread   = Thread.new { serve }
  end

  def base_url
    "#{@tls ? 'https' : 'http'}://127.0.0.1:#{port}"
  end

  # Returns [Array(OpenSSL::X509::Certificate, OpenSSL::PKey::RSA)] the self-signed certificate
  # for 127.0.0.1 that the server uses with `tls: true`, and its key.
  def self.certificate
    @certificate ||= begin
      key                    = OpenSSL::PKey::RSA.new(2048)
      cert                   = OpenSSL::X509::Certificate.new
      cert.version           = 2
      cert.serial            = 1
      cert.subject           = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
      cert.issuer            = cert.subject
      cert.public_key        = key.public_key
      cert.not_before        = Time.now - 60
      cert.not_after         = Time.now + 3600
      extensions             = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = cert
      extensions.issuer_certificate  = cert
      cert.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
      cert.add_extension(extensions.create_extension("subjectAltName", "IP:127.0.0.1"))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))
      [cert, key]
    end
  end

  # Trusts only the certificate of `.certificate` for HTTPS requests made within the block.
  def self.trust_certificate
    store = OpenSSL::X509::Store.new
    store.add_cert(certificate.first)
    previous = OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE
    replace_default_cert_store(store)
    yield
  ensure
    replace_default_cert_store(previous) if previous
  end

  def self.replace_default_cert_store(store)
    OpenSSL::SSL::SSLContext.send(:remove_const, :DEFAULT_CERT_STORE)
    OpenSSL::SSL::SSLContext.const_set(:DEFAULT_CERT_STORE, store)
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
              404 => "Not Found", 405 => "Method Not Allowed", 410 => "Gone", 500 => "Internal Server Error"}[status]
    all    = {"Content-Length" => body.bytesize.to_s, "Connection" => "close"}.merge(headers)
    lines  = ["HTTP/1.1 #{status} #{reason}"]
    all.each { |key, value| lines << "#{key}: #{value}" }
    lines << ""
    lines << body
    lines.join("\r\n")
  end

  private

  def ssl_context
    context      = OpenSSL::SSL::SSLContext.new
    context.cert = self.class.certificate.first
    context.key  = self.class.certificate.last
    context
  end

  def serve
    loop do
      client = accept
      handle_client(client) if client
    end
  rescue IOError, Errno::EBADF
    # Server was shut down.
  end

  # Returns the next connection, or nil when the client rejected the TLS handshake.
  def accept
    @server.accept
  rescue OpenSSL::SSL::SSLError
    nil
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
