# frozen_string_literal: true

require_relative "query_helper"

# Reads a query on SQLite with a statement of the sqlite3 gem, see `IOStreams::Query::SqliteStatement`.
class SqliteStatementTest < Minitest::Test
  if (database = QueryDatabase.all.find { |db| db.name == "SQLite" })
    describe IOStreams::Query::SqliteStatement do
      let(:db) { database }
      let(:orders) { db.order.order(:id) }

      before { db.load }

      # Yields with the statements of the SQL of the relation that the raw connection prepares within the block, rather
      # than those of Active Record itself.
      def capture_statements(relation)
        raw        = db.raw_connection
        sql        = relation.to_sql
        statements = []
        prepare    = raw.method(:prepare)
        capture    = ->(text) { prepare.call(text).tap { |statement| statements << statement if text == sql } }
        raw.stub(:prepare, capture) { yield statements }
      end

      it "reads a connection of the sqlite3 gem" do
        assert(db.record.with_connection { |connection| IOStreams::Query::SqliteStatement.reads?(connection) })
      end

      it "reads the query with one statement, which it closes" do
        capture_statements(orders) do |statements|
          records = []
          IOStreams.stream(orders).each(:hash) { |order| records << order }

          assert_equal 3, records.size
          assert_equal 1, statements.size
          assert_predicate statements.first, :closed?
        end
      end

      it "closes the statement when the block breaks out of the loop, or raises" do
        capture_statements(orders) do |statements|
          # rubocop:disable Lint/UnreachableLoop -- leaves on its first row on purpose
          IOStreams.stream(orders).each(:hash) { |_order| break }
          assert_raises(RuntimeError) { IOStreams.stream(orders).each(:hash) { |_order| raise "stop" } }
          # rubocop:enable Lint/UnreachableLoop

          assert_equal 2, statements.size
          assert(statements.all?(&:closed?))
        end
      end

      it "tags a database that another connection has locked as Unavailable" do
        stream = IOStreams.stream(orders)
        # The columns are described with Active Record, which raises its own exception, see QueryStreamTest.
        stream.schema
        error = assert_raises(SQLite3::BusyException) do
          db.raw_connection.stub(:prepare, ->(_sql) { raise SQLite3::BusyException, "database is locked" }) do
            stream.each(:hash) { |_order| nil }
          end
        end

        assert_kind_of IOStreams::Errors::Unavailable, error
        assert_equal "#{db.order.name} query: database is locked", error.message
      end

      describe ".failure_kind" do
        it "returns the kind of failure of an exception of the sqlite3 gem" do
          assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::SqliteStatement.failure_kind(SQLite3::BusyException.new("busy"))
          assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::SqliteStatement.failure_kind(SQLite3::LockedException.new("locked"))
          assert_equal IOStreams::Errors::PermissionDenied,
                       IOStreams::Query::SqliteStatement.failure_kind(SQLite3::PermissionException.new("denied"))
          assert_equal IOStreams::Errors::PermissionDenied,
                       IOStreams::Query::SqliteStatement.failure_kind(SQLite3::AuthorizationException.new("denied"))
          assert_nil IOStreams::Query::SqliteStatement.failure_kind(SQLite3::SQLException.new("syntax error"))
          assert_nil IOStreams::Query::SqliteStatement.failure_kind(RuntimeError.new("other"))
        end
      end
    end
  end
end
