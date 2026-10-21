# frozen_string_literal: true

require_relative "query_helper"

# The kind of failure of each exception of the trilogy gem, see `IOStreams::Query::TrilogyFailure`.
class TrilogyFailureTest < Minitest::Test
  describe IOStreams::Query::TrilogyFailure do
    before do
      skip "The trilogy gem is not installed, see the mysql group of the Gemfile" unless QueryDatabase.driver?("trilogy")
    end

    def kind(exception)
      IOStreams::Query::TrilogyFailure.failure_kind(exception)
    end

    # Returns [Trilogy::Error] the exception that trilogy raises for the error that the server sent, as its C extension
    # makes it, which is of the class that trilogy gives the error number.
    def server_error(number, message)
      Trilogy::ProtocolError.from_code(message, number)
    end

    it "returns what MySQL says of the error number that the server sent, whatever the class that trilogy gives it" do
      assert_equal IOStreams::Errors::PermissionDenied,
                   kind(server_error(1142, "SELECT command denied to user 'jack'@'%' for table 'orders' (trilogy_query_recv)"))
      # trilogy raises it as a connection error, which it says may be transient.
      denied = server_error(1044, "Access denied for user 'jack'@'%' to database 'shop' (trilogy_auth_recv)")

      assert_kind_of Trilogy::ConnectionError, denied
      assert_equal IOStreams::Errors::PermissionDenied, kind(denied)
      assert_equal IOStreams::Errors::Unavailable,
                   kind(server_error(1205, "Lock wait timeout exceeded; try restarting transaction (trilogy_query_recv)"))
      assert_nil kind(server_error(1146, "Table 'shop.order' doesn't exist (trilogy_query_recv)"))
    end

    it "tags a timeout, a connection that the server closed, or a server that cannot be reached as Unavailable" do
      [
        Trilogy::TimeoutError.new("trilogy_query_recv"),
        Trilogy::EOFError.new("trilogy_query_recv: TRILOGY_CLOSED_CONNECTION"),
        Trilogy::SyscallError.from_errno(Errno::ECONNREFUSED::Errno, "Connection refused - connect(2) for \"db\" port 3306"),
        Trilogy::SyscallError.from_errno(Errno::ECONNRESET::Errno, "Connection reset by peer - trilogy_query_recv")
      ].each do |exception|
        assert_equal IOStreams::Errors::Unavailable, kind(exception), exception.inspect
      end
    end

    # Returns [Trilogy::BaseConnectionError] the exception that trilogy raises when the socket of Ruby that it connects
    # with cannot resolve the host, whose cause is the failure of the socket.
    def unresolved(error_code)
      raise resolution_error(error_code)
    rescue SocketError => e
      begin
        raise Trilogy::BaseConnectionError, "unable to connect to \"db.example.com:3306\": #{e.message}"
      rescue Trilogy::BaseConnectionError => error
        error
      end
    end

    it "tags a temporary failure to resolve the host as Unavailable, and any other as no kind of failure" do
      skip_without_resolution_error

      assert_equal IOStreams::Errors::Unavailable, kind(unresolved(Socket::EAI_AGAIN))
      assert_same IOStreams::Query::Failure::NONE, kind(unresolved(Socket::EAI_NONAME))
    end

    it "does not tag any other exception" do
      [
        Trilogy::SSLError.new("trilogy_connect: SSL Error: certificate verify failed"),
        Trilogy::QueryError.new("trilogy_query_send: TRILOGY_TRUNCATED_PACKET"),
        Trilogy::SyscallError.from_errno(Errno::ENOENT::Errno, "No such file or directory - connect(2) for /tmp/mysql.sock"),
        RuntimeError.new("other")
      ].each do |exception|
        assert_nil kind(exception), exception.inspect
      end
    end
  end
end
