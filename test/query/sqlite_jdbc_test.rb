# frozen_string_literal: true

require_relative "query_helper"

# Reads a query on SQLite with the SQLite adapter of AR-JDBC, on JRuby, see `IOStreams::Query::SqliteJdbc`.
class SqliteJdbcTest < Minitest::Test
  if (database = QueryDatabase.find("SQLite")) && QueryDatabase.jdbc?
    describe IOStreams::Query::SqliteJdbc do
      include QueryTestMethods

      let(:db) { database }
      let(:orders) { db.order.order(:id) }

      before { db.load }

      # Returns [ActiveRecord::JDBCError] an exception of sqlite-jdbc of the supplied result code of SQLite, see
      # `org.sqlite.SQLiteErrorCode`, as AR-JDBC raises it.
      def sqlite_error(code, message = "failed")
        ActiveRecord::JDBCError.new(nil, Java::OrgSqlite::SQLiteException.new(message, Java::OrgSqlite::SQLiteErrorCode.const_get(code)))
      end

      it "reads a connection of the SQLite adapter of AR-JDBC, rather than one of the sqlite3 gem" do
        db.record.with_connection do |connection|
          assert IOStreams::Query::SqliteJdbc.reads?(connection)
          refute IOStreams::Query::SqliteStatement.reads?(connection)
        end
      end

      it "tells that it reads a connection without asking its raw connection, which Active Record would then not verify" do
        db.record.with_connection do |connection|
          connection.stub(:raw_connection, -> { flunk "asked the raw connection" }) do
            assert IOStreams::Query::SqliteJdbc.reads?(connection)
          end
        end
      end

      describe ".own_connection?" do
        it "reads a database in WAL mode, the default of Rails, on a connection of its own" do
          assert(db.record.with_connection { |connection| IOStreams::Query::SqliteJdbc.own_connection?(connection) })
        end

        it "reads any other database on the connection of the caller" do
          Dir.mktmpdir do |dir|
            QueryDatabase::SQLite.send(:remove_const, :JournalRecord) if QueryDatabase::SQLite.const_defined?(:JournalRecord)
            record = QueryDatabase::SQLite.const_set(:JournalRecord, Class.new(ActiveRecord::Base) { self.abstract_class = true })
            record.establish_connection(adapter: "sqlite3", database: File.join(dir, "journal.sqlite3"), pool: 1)
            record.with_connection do |connection|
              connection.execute("PRAGMA journal_mode = DELETE")

              refute IOStreams::Query::SqliteJdbc.own_connection?(connection)
            end
          ensure
            record&.remove_connection
          end

          QueryDatabase.memory.record.with_connection do |connection|
            refute IOStreams::Query::SqliteJdbc.own_connection?(connection)
          end
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

      it "reads the first row before it yields, so that a failure of the first row raises before the block runs" do
        relation = orders.select(Arel.sql("abs(-9223372036854775807 - 1) AS overflow"))
        stream   = IOStreams.stream(relation)
        stream.infer_schema
        error = assert_raises(ActiveRecord::JDBCError) { stream.reader(:hash) { |_reader| flunk "The block ran" } }

        assert_match(/integer overflow/, error.message)
      end

      it "reads the query with one statement, and its columns with Active Record" do
        names = statements { assert_equal 3, each(IOStreams.stream(orders)).size }

        assert_equal ["IOStreams Columns", "IOStreams Query"], names
      end

      it "ends the statement when the block breaks out of the loop, or raises" do
        rows     = []
        new_rows = IOStreams::Query::JdbcRows.method(:new)
        IOStreams::Query::JdbcRows.stub(:new, ->(raw) { new_rows.call(raw).tap { |read| rows << read } }) do
          # rubocop:disable Lint/UnreachableLoop -- leaves on its first row on purpose
          IOStreams.stream(orders).each(:hash) { |_order| break }
          assert_raises(RuntimeError) { IOStreams.stream(orders).each(:hash) { |_order| raise "stop" } }
          # rubocop:enable Lint/UnreachableLoop
        end

        assert_equal 2, rows.size
        refute(rows.any?(&:reading?))
      end

      it "reads the rows on another thread than the one that opened the reader, as the other sources do" do
        names = IOStreams.stream(orders).reader(:hash) do |reader|
          Thread.new { reader.map { |order| order["name"] } }.value
        end

        assert_equal %w[a b c], names
      end

      it "tags a database that another connection has locked as Unavailable" do
        stream = IOStreams.stream(orders)
        # The columns are described with Active Record, which raises its own exception, see QueryStreamTest.
        stream.infer_schema
        locked = Object.new
        busy   = sqlite_error(:SQLITE_BUSY, "[SQLITE_BUSY] The database file is locked (database is locked)")
        locked.define_singleton_method(:start) { |_sql, _binds| raise busy }
        locked.define_singleton_method(:close) { nil }
        error = assert_raises(ActiveRecord::JDBCError) do
          IOStreams::Query::JdbcRows.stub(:new, ->(_raw) { locked }) { stream.each(:hash) { |_order| nil } }
        end

        assert_kind_of IOStreams::Errors::Unavailable, error
        assert_equal "#{db.order.name} query: [SQLITE_BUSY] The database file is locked (database is locked)", error.message
      end

      describe ".failure_kind" do
        it "returns the kind of failure of the result code of an exception of sqlite-jdbc, apart from its extended code" do
          assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::SqliteJdbc.failure_kind(sqlite_error(:SQLITE_BUSY))
          assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::SqliteJdbc.failure_kind(sqlite_error(:SQLITE_LOCKED))
          assert_equal IOStreams::Errors::Unavailable,
                       IOStreams::Query::SqliteJdbc.failure_kind(sqlite_error(:SQLITE_BUSY_SNAPSHOT))
          assert_equal IOStreams::Errors::PermissionDenied, IOStreams::Query::SqliteJdbc.failure_kind(sqlite_error(:SQLITE_PERM))
          assert_equal IOStreams::Errors::PermissionDenied, IOStreams::Query::SqliteJdbc.failure_kind(sqlite_error(:SQLITE_AUTH))
          assert_nil IOStreams::Query::SqliteJdbc.failure_kind(sqlite_error(:SQLITE_ERROR))
          assert_nil IOStreams::Query::SqliteJdbc.failure_kind(RuntimeError.new("other"))
        end
      end
    end
  end
end
