# frozen_string_literal: true

require_relative "query_helper"

# Reads a query on SQLite with a statement of the sqlite3 gem, see `IOStreams::Query::SqliteStatement`.
class SqliteStatementTest < Minitest::Test
  if (database = QueryDatabase.find("SQLite"))
    describe IOStreams::Query::SqliteStatement do
      include QueryTestMethods

      let(:db) { database }
      let(:orders) { db.order.order(:id) }

      before { db.load }

      # Yields with the statements of the SQL of the relation that are prepared within the block, on any connection,
      # rather than those of Active Record itself.
      def capture_statements(relation)
        sql        = db.record.with_connection { |connection| IOStreams::Query::Statement.new(connection, relation.arel).sql }
        statements = []
        prepare    = SQLite3::Statement.method(:new)
        capture    = ->(raw, text) { prepare.call(raw, text).tap { |statement| statements << statement if text == sql } }
        SQLite3::Statement.stub(:new, capture) { yield statements }
      end

      it "reads a connection of the sqlite3 gem" do
        assert(db.record.with_connection { |connection| IOStreams::Query::SqliteStatement.reads?(connection) })
      end

      it "tells that it reads a connection without asking its raw connection, which Active Record would then not verify" do
        db.record.with_connection do |connection|
          connection.stub(:raw_connection, -> { flunk "asked the raw connection" }) do
            assert IOStreams::Query::SqliteStatement.reads?(connection)
          end
        end
      end

      describe ".own_connection?" do
        # Returns [Object] a connection whose raw connection is the supplied database of the sqlite3 gem.
        def connection(raw)
          Struct.new(:raw_connection).new(raw)
        end

        it "reads a database in WAL mode, the default of Rails, on a connection of its own" do
          assert(db.record.with_connection { |connection| IOStreams::Query::SqliteStatement.own_connection?(connection) })
        end

        it "reads any other database on the connection of the caller" do
          Dir.mktmpdir do |dir|
            raw = SQLite3::Database.new(File.join(dir, "journal.sqlite3"))
            raw.journal_mode = "delete"

            refute IOStreams::Query::SqliteStatement.own_connection?(connection(raw))
          ensure
            raw&.close
          end
          memory = SQLite3::Database.new(":memory:")

          refute IOStreams::Query::SqliteStatement.own_connection?(connection(memory))
        ensure
          memory&.close
        end
      end

      it "reads an in-memory database on the connection of the caller, without another, which would be a database of its own" do
        memory = QueryDatabase.memory
        memory.load
        names = []
        memory.record.with_connection do
          IOStreams.stream(memory.order.order(:id)).each(:hash) { |order| names << order["name"] }
        end

        assert_equal %w[a b c], names
        assert_equal 1, memory.pool.stat[:connections]
      end

      it "steps to the first row before it yields, so that a failure of the first row raises before the block runs" do
        relation = orders.select(Arel.sql("abs(-9223372036854775807 - 1) AS overflow"))
        stream   = IOStreams.stream(relation)
        stream.schema
        error = assert_raises(SQLite3::SQLException) { stream.reader(:hash) { |_reader| flunk "The block ran" } }

        assert_equal "integer overflow", error.message
      end

      it "reads the query with one statement, which it closes, and its columns with Active Record" do
        capture_statements(orders) do |prepared|
          names = statements { assert_equal 3, each(IOStreams.stream(orders)).size }

          assert_equal ["IOStreams Columns", "IOStreams Query"], names
          assert_equal 1, prepared.size
          assert_predicate prepared.first, :closed?
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
          SQLite3::Statement.stub(:new, ->(_raw, _sql) { raise SQLite3::BusyException, "database is locked" }) do
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
