# frozen_string_literal: true

require_relative "query_helper"

# The kind of failure of each error of MySQL, whichever driver raised it, see `IOStreams::Query::MysqlFailure`.
class MysqlFailureTest < Minitest::Test
  describe IOStreams::Query::MysqlFailure do
    def kind(number, message = "failed")
      IOStreams::Query::MysqlFailure.kind(number, message)
    end

    it "tags an access that MySQL denies as PermissionDenied" do
      [1044, 1045, 1142, 1143, 1227, 1370].each do |number|
        assert_equal IOStreams::Errors::PermissionDenied, kind(number), number
      end
    end

    it "tags an account that MySQL does not let connect as PermissionDenied, such as one that is locked" do
      [1130, 1698, 1820, 1862, 3118, 3955].each do |number|
        assert_equal IOStreams::Errors::PermissionDenied, kind(number), number
      end
    end

    it "tags a server that could not be reached, lost the connection, or could not run the query at the time as Unavailable" do
      [1040, 1053, 1205, 1213, 1317, 2002, 2003, 2006, 2013, 3024, 4031].each do |number|
        assert_equal IOStreams::Errors::Unavailable, kind(number), number
      end
    end

    it "does not tag any other error, such as a table that does not exist, or a host that does not resolve" do
      [1146, 1064, 2005].each { |number| assert_nil kind(number), number }
    end

    # The messages as mysql2 raises them while it streams a result, without their number: of the client library of
    # Oracle and that of MariaDB, and of the server.
    it "tags an error that the driver raised without its number by its message" do
      [
        "Lost connection to MySQL server during query",
        "Lost connection to server during query",
        "Lost connection to MySQL server at 'reading initial communication packet', system error: 0",
        "MySQL server has gone away",
        "Server has gone away",
        "Query execution was interrupted",
        "Query execution was interrupted, maximum statement execution time exceeded",
        "Server shutdown in progress",
        "The client was disconnected by the server because of inactivity. See wait_timeout and interactive_timeout for " \
        "configuring this behavior."
      ].each do |message|
        assert_equal IOStreams::Errors::Unavailable, kind(nil, message), message
      end
    end

    it "does not tag any other error without a number, such as a value that mysql2 cannot cast" do
      [
        "Invalid date in field 'shipped_on': 2026-00-15",
        "Recursive query aborted after 1001 iterations. Try increasing @@cte_max_recursion_depth to a larger value.",
        "You have already fetched all the rows for this query and streaming is true. (to reiterate you must requery).",
        "Mentions a Lost connection to MySQL server during query"
      ].each do |message|
        assert_nil kind(nil, message), message
      end
    end

    it "decides by the number of an error that has one, rather than by its message" do
      assert_nil kind(1146, "Lost connection to MySQL server during query")
    end
  end
end
