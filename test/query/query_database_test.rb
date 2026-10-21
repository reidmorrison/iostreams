# frozen_string_literal: true

require_relative "query_helper"

# Checks that each database that the query tests read was set up, see QueryDatabase.all, since the tests of a database
# that could not be set up, such as a PostgreSQL server that cannot be reached, do not run, while those of the others do.
class QueryDatabaseTest < Minitest::Test
  describe QueryDatabase do
    it "sets up each database that the query tests read" do
      QueryDatabase.all
      failures = QueryDatabase.failures.map { |name, error| "#{name}: #{error.class}: #{error.message}" }

      assert_empty failures, "The query tests of these databases did not run, since they could not be set up"
    end
  end
end
