# frozen_string_literal: true

require_relative "query_helper"

# The kind of failure of each error of MySQL, whichever driver raised it, see `IOStreams::Query::MysqlFailure`.
class MysqlFailureTest < Minitest::Test
  describe IOStreams::Query::MysqlFailure do
    def kind(number)
      IOStreams::Query::MysqlFailure.kind(number)
    end

    it "tags an access that MySQL denies as PermissionDenied" do
      [1044, 1045, 1142, 1143, 1227].each do |number|
        assert_equal IOStreams::Errors::PermissionDenied, kind(number), number
      end
    end

    it "tags a server that could not be reached, lost the connection, or could not run the query at the time as Unavailable" do
      [1040, 1053, 1205, 1213, 1317, 2002, 2003, 2006, 2013, 3024].each do |number|
        assert_equal IOStreams::Errors::Unavailable, kind(number), number
      end
    end

    it "does not tag any other error, such as a table that does not exist, or a host that does not resolve" do
      [1146, 1064, 2005].each { |number| assert_nil kind(number), number }
    end
  end
end
