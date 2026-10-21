# frozen_string_literal: true

require_relative "query_helper"

# The SQL of a query as Active Record runs it, see `IOStreams::Query::Statement`, on each database of QueryDatabase.
class QueryStatementTest < Minitest::Test
  QueryDatabase.each do |database|
    describe "#{IOStreams::Query::Statement.name} on #{database.name}" do
      let(:db) { database }
      let(:relation) { db.order.where(name: "a").order(:id) }

      # Returns [IOStreams::Query::Statement] the statement of the relation on a connection that the caller borrows.
      def statement(relation)
        db.record.with_connection { |connection| IOStreams::Query::Statement.new(connection, relation.arel) }
      end

      it "has the SQL of Active Record, with a placeholder for each bind, and the binds that it sends" do
        statement = statement(relation)

        refute_equal relation.to_sql, statement.sql
        assert_equal 1, statement.binds.size
        assert_equal "a", statement.binds.first.value
      end

      it "casts the value of each bind for the driver, as Active Record casts it" do
        statement = statement(db.order.where(name: "a").where("amount < ?", Rational(7, 2)))
        expected  = db.record.with_connection { |connection| [connection.type_cast("a"), connection.type_cast(Rational(7, 2))] }

        assert_equal expected, statement.type_casted_binds
      end

      it "has the binds written into the SQL, as Active Record writes them, when the connection does not prepare them" do
        statement = db.record.with_connection do |connection|
          connection.unprepared_statement { IOStreams::Query::Statement.new(connection, relation.arel) }
        end

        assert_equal relation.to_sql, statement.sql
        assert_empty statement.binds
      end

      it "has the binds written into the SQL, as Active Record writes them, when there are more than the database takes" do
        relation  = db.order.where(id: (1..70_000).to_a)
        statement = statement(relation)

        assert_equal relation.to_sql, statement.sql
        assert_empty statement.binds
      end
    end
  end
end
