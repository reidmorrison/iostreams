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

      # Skips a test of the binds of a connection that prepares statements, which a connection of mysql2 does not, unless
      # it is configured to.
      def skip_unless_prepared
        skip "#{db.name} does not prepare statements by default" unless db.record.with_connection(&:prepared_statements?)
      end

      it "has the SQL of Active Record, with a placeholder for each bind, and the binds that it sends" do
        skip_unless_prepared
        statement = statement(relation)

        refute_equal relation.to_sql, statement.sql
        assert_equal 1, statement.binds.size
        assert_equal "a", statement.binds.first.value
      end

      it "casts the value of each bind for the driver, as Active Record casts it" do
        skip_unless_prepared
        statement = statement(db.order.where(name: "a").where("amount < ?", Rational(7, 2)))
        expected  = db.record.with_connection { |connection| [connection.type_cast("a"), connection.type_cast(Rational(7, 2))] }

        assert_equal(expected, statement.instrument { |_sql, binds| binds })
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

      describe "#instrument" do
        # Returns [Array] what the block of #instrument yields, and the payload of each `sql.active_record` event.
        def instrument(statement)
          payloads = []
          callback = ->(_name, _start, _finish, _id, payload) { payloads << payload }
          yielded  = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
            statement.instrument { |sql, binds| [sql, binds] }
          end
          [yielded, payloads]
        end

        it "yields the SQL and the binds, type cast for the driver, within an event of Active Record" do
          skip_unless_prepared
          statement = statement(relation)
          expected  = db.record.with_connection { |connection| [connection.type_cast("a")] }
          (sql, binds), payloads = instrument(statement)

          assert_equal statement.sql, sql
          assert_equal expected, binds
          assert_equal 1, payloads.size
          assert_equal "IOStreams Query", payloads.first[:name]
          assert_equal sql, payloads.first[:sql]
          assert_equal statement.binds, payloads.first[:binds]
          assert_equal binds, payloads.first[:type_casted_binds]
        end

        it "applies the query transformers of Active Record to the SQL, as Active Record does, such as for query logs" do
          transformer = ->(sql, connection) { "#{sql} /* #{connection.adapter_name} */" }
          ActiveRecord.query_transformers << transformer
          statement = statement(relation)
          adapter   = db.record.with_connection(&:adapter_name)
          (sql, _binds), payloads = instrument(statement)

          assert_equal "#{statement.sql} /* #{adapter} */", sql
          assert_equal sql, payloads.first[:sql]
        ensure
          ActiveRecord.query_transformers.delete(transformer)
        end

        it "returns the result of the block, and reports what it raises" do
          statement = statement(relation)
          payloads  = []
          callback  = ->(_name, _start, _finish, _id, payload) { payloads << payload }
          ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
            assert_equal(5, statement.instrument { 5 })
            assert_raises(IOError) { statement.instrument { raise IOError, "failed" } }
          end

          assert_equal 2, payloads.size
          assert_instance_of IOError, payloads.last[:exception_object]
        end
      end
    end
  end
end
