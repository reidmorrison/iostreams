# frozen_string_literal: true

require_relative "query_helper"

# Reads a query on PostgreSQL with a cursor, see `IOStreams::Query::PostgresqlCursor`, when POSTGRES_URL is set.
class PostgresqlCursorTest < Minitest::Test
  if (database = QueryDatabase.find("PostgreSQL"))
    describe IOStreams::Query::PostgresqlCursor do
      include QueryTestMethods

      let(:db) { database }
      let(:orders) { db.order.order(:id) }

      before { db.load }

      # Runs the SQL on the connection of the pool.
      def execute(sql)
        db.record.with_connection { |connection| connection.execute(sql) }
      end

      # Returns [String] the value of the setting of the connection of the pool.
      def setting(name)
        db.record.with_connection { |connection| connection.select_value("SHOW #{name}") }
      end

      # Adds the supplied number of orders, so that reading them takes more than one fetch.
      def add_orders(count)
        execute("INSERT INTO orders (name, amount, status) SELECT 'x' || i, i, 0 FROM generate_series(1, #{count}) AS i")
      end

      # Returns [Integer] the number of the cursors of IOStreams that are open on the supplied connection, otherwise that of
      # the pool, rather than the unnamed portal of the query that counts them, which Active Record 7.2 lists there too.
      def open_cursors(connection = nil)
        sql = "SELECT count(*) FROM pg_cursors WHERE name LIKE 'iostreams_cursor_%'"
        connection ? connection.select_value(sql) : db.record.with_connection { |caller| caller.select_value(sql) }
      end

      # Yields an Array, to which the connection of each query that is read within the block is added as soon as its cursor
      # is declared, which is reported as the statement of the query, see `IOStreams::Query::Statement::NAME`, so that the
      # block that its rows are yielded to can ask the connection of the read.
      def with_read_connections
        connections = []
        callback    = lambda do |_name, _start, _finish, _id, payload|
          connections << payload[:connection] if payload[:name] == IOStreams::Query::Statement::NAME
        end
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield connections }
      end

      # Yields with the connection of the pool pinned, as the transactional tests of Rails pin it, in a transaction of the
      # test, which the pool checks out for a read too, see `IOStreams::Query#open`, and rolls back afterwards.
      def pinned
        db.pool.pin_connection!(false)
        yield
      ensure
        db.pool.unpin_connection!
      end

      it "reads a connection to PostgreSQL" do
        assert(db.record.with_connection { |connection| IOStreams::Query::PostgresqlCursor.reads?(connection) })
      end

      it "fetches the rows of the query FETCH_SIZE at a time, from one query" do
        add_orders(25_000)
        count = 0
        names = statements { IOStreams.stream(orders).each(:hash) { |_order| count += 1 } }

        assert_equal 25_003, count
        assert_equal 3, names.count("IOStreams Fetch")
        assert_equal 1, names.count("IOStreams Columns")
      end

      it "plans the query for every row, and keeps the transaction open while the block is slow, on its own connection" do
        names    = %w[cursor_tuple_fraction idle_in_transaction_session_timeout]
        settings = []
        read     = with_read_connections do |connections|
          IOStreams.stream(orders).each(:hash) do |_order|
            settings << names.map { |name| connections.last.select_value("SHOW #{name}") }
          end
          connections.last
        end

        assert_equal [%w[1 0]] * 3, settings
        assert_equal "0.1", read.select_value("SHOW cursor_tuple_fraction")
        assert_equal "0.1", setting("cursor_tuple_fraction")
      end

      it "reads in a savepoint of a connection whose transaction is open, as in transactional tests, whose settings it " \
         "sets back" do
        pinned do
          execute("SET LOCAL cursor_tuple_fraction = 0.2")
          execute("SET LOCAL idle_in_transaction_session_timeout = '5min'")
          names = statements { assert_equal 3, each(IOStreams.stream(orders)).size }

          assert_includes names, "TRANSACTION"
          assert_equal "0.2", setting("cursor_tuple_fraction")
          assert_equal "5min", setting("idle_in_transaction_session_timeout")
        end
      end

      it "applies the statement_timeout of the connection to each fetch, rather than to the whole query" do
        add_orders(25_000)
        count = 0
        IOStreams.stream(orders_with("Timeout", statement_timeout: 500).order(:id)).each(:hash) do |_order|
          sleep(0.3) if (count % IOStreams::Query::PostgresqlCursor::FETCH_SIZE).zero?
          count += 1
        end

        assert_equal 25_003, count
      end

      it "keeps the connection while the block is slower than the idle_in_transaction_session_timeout of the connection" do
        names = []
        IOStreams.stream(orders_with("Idle", idle_in_transaction_session_timeout: 200).order(:id)).each(:hash) do |order|
          sleep(0.5)
          names << order["name"]
        end

        assert_equal %w[a b c], names
      end

      it "closes the cursor when the block breaks out of the loop, or raises" do
        pinned do
          IOStreams.stream(orders).each(:hash) { |_order| break } # rubocop:disable Lint/UnreachableLoop -- leaves on its first row on purpose

          assert_equal 0, open_cursors

          assert_raises(RuntimeError) do
            IOStreams.stream(orders).each(:hash) { |_order| raise "stop" } # rubocop:disable Lint/UnreachableLoop -- raises on its first row on purpose
          end

          assert_equal 0, open_cursors
          assert_equal "0.1", setting("cursor_tuple_fraction")
        end
      end

      it "ends a transaction of its own, on its own connection, when the block breaks out of the loop" do
        read = with_read_connections do |connections|
          IOStreams.stream(orders).each(:hash) { |_order| break } # rubocop:disable Lint/UnreachableLoop -- leaves on its first row on purpose
          connections.last
        end

        refute_predicate read, :transaction_open?
        assert_equal 0, open_cursors(read)
        assert_equal 0, db.pool.stat[:busy]
      end

      it "reads another query within the block, with a cursor of its own" do
        pairs = []
        IOStreams.stream(orders.select(:name)).each(:hash) do |order|
          IOStreams.stream(db.customer.order(:id).select(:name)).each(:hash) do |customer|
            pairs << [order["name"], customer["name"]]
          end
        end

        assert_equal [%w[a Acme], %w[a Globex], %w[b Acme], %w[b Globex], %w[c Acme], %w[c Globex]], pairs
      end

      it "raises the failure of a fetch, tagged as Unavailable, which rolls back only its savepoint of an open transaction" do
        relation = db.order.select("pg_sleep(0.3)::text AS slept")
        stream   = IOStreams.stream(relation)
        stream.schema
        pinned do
          execute("SET LOCAL statement_timeout = '100ms'")
          error = assert_raises(ActiveRecord::QueryCanceled) { each(stream) }

          assert_kind_of IOStreams::Errors::Unavailable, error
          assert_match(/\A#{db.order.name} query: PG::QueryCanceled: ERROR:  canceling statement due to statement timeout/,
                       error.message)
          assert_equal 3, db.order.count
        end
      end

      it "tags a table that the user may not read as PermissionDenied" do
        execute(<<~SQL)
          DO $$ BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'iostreams_reader') THEN CREATE ROLE iostreams_reader; END IF;
          END $$
        SQL
        stream = IOStreams.stream(orders)
        stream.schema
        pinned do
          execute("SET LOCAL ROLE iostreams_reader")
          error = assert_raises(ActiveRecord::StatementInvalid) { each(stream) }

          assert_kind_of IOStreams::Errors::PermissionDenied, error
          assert_match(/permission denied for table orders/, error.message)
        end
      end

      # Returns [Class] a model of the orders table on a connection to the url of POSTGRES_URL, changed by the block.
      def orders_at(name)
        url = URI(ENV.fetch("POSTGRES_URL"))
        yield url
        record = Class.new(ActiveRecord::Base) { self.abstract_class = true }
        constant = :"#{name}Record"
        QueryDatabase::PostgreSQL.send(:remove_const, constant) if QueryDatabase::PostgreSQL.const_defined?(constant)
        QueryDatabase::PostgreSQL.const_set(constant, record)
        record.establish_connection(url: url.to_s, pool: 1, connect_timeout: 2)
        Class.new(record) { self.table_name = "orders" }
      end

      # Returns [Class] a model of the orders table, on a pool of one connection of its own, whose connections set the
      # supplied variables, such as `statement_timeout`, as the `variables` of the configuration of a database do.
      def orders_with(name, variables)
        record = Class.new(ActiveRecord::Base) { self.abstract_class = true }
        constant = :"#{name}Record"
        QueryDatabase::PostgreSQL.send(:remove_const, constant) if QueryDatabase::PostgreSQL.const_defined?(constant)
        QueryDatabase::PostgreSQL.const_set(constant, record)
        record.establish_connection(db.record.connection_db_config.configuration_hash.merge(pool: 1, variables: variables))
        Class.new(record) { self.table_name = "orders" }
      end

      it "tags a server that refuses the connection as Unavailable" do
        orders = orders_at("Refused") { |url| url.port = 1 }
        error  = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(orders.all)) }

        assert_kind_of IOStreams::Errors::Unavailable, error
        assert_match(/Connection refused/, error.cause.message)
      end

      it "tags a password that the server rejects as PermissionDenied" do
        orders = orders_at("Rejected") { |url| url.password = "wrong" }
        error  = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(orders.all)) }

        assert_kind_of IOStreams::Errors::PermissionDenied, error
      end

      it "does not tag a host that does not resolve" do
        orders = orders_at("Unknown") { |url| url.host = "iostreams-no-such-host.invalid" }
        error  = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(orders.all)) }

        refute_kind_of IOStreams::Errors::StorageError, error
      end

      it "reads the rows of each batch in the order of the primary key, after updates move them" do
        add_orders(3_000)
        execute("UPDATE orders SET name = name || '!' WHERE id % 3 = 0")
        ids = each(IOStreams.stream(db.order.select(:id).in_batches(of: 2_000))).map { |order| order["id"] }

        assert_equal 3_003, ids.size
        assert_equal ids.sort, ids
      end

      it "does not clear the query cache of the application" do
        db.record.cache do
          db.order.first
          db.customer.first

          assert_equal 3, each(IOStreams.stream(orders)).size
          assert_equal 2, db.pool.query_cache.size
        end
      end

      describe "the types of PostgreSQL" do
        let(:model) do
          QueryDatabase::PostgreSQL.const_set(:PgType, Class.new(db.record) { self.table_name = "pg_types" }) unless
            QueryDatabase::PostgreSQL.const_defined?(:PgType)
          QueryDatabase::PostgreSQL::PgType
        end

        before do
          execute("DROP TABLE IF EXISTS pg_types")
          execute("DROP TYPE IF EXISTS mood")
          execute("CREATE TYPE mood AS ENUM ('sad', 'happy')")
          execute(<<~SQL)
            CREATE TABLE pg_types (
              id bigserial PRIMARY KEY, code uuid NOT NULL, doc jsonb, ints integer[], words text[], total numeric,
              price numeric(12, 3), cost money, wait interval, host inet, mac macaddr, seen timestamptz, opens time,
              blob bytea, feeling mood, whole numeric(10, 0), network cidr, address inet
            )
          SQL
          execute(<<~SQL)
            INSERT INTO pg_types (code, doc, ints, words, total, price, cost, wait, host, mac, seen, opens, blob, feeling, whole,
                                  network, address)
            VALUES ('9b3e9a64-4b7a-4b4e-9e8e-2f1d7c1a6b55', '{"a": [1, 2]}', '{1,2}', '{x,"y z"}', 12.345678, 1.5, 9.99,
                    '1 day 2 hours', '192.168.0.1', '08:00:2b:01:02:03', '2026-10-20 12:30:00+02', '09:15', '\\x0102',
                    'happy', 42, '10.0.0.0/8', '192.168.1.5/24')
          SQL
          model.reset_column_information
        end

        after do
          execute("DROP TABLE IF EXISTS pg_types")
          execute("DROP TYPE IF EXISTS mood")
        end

        it "describes the columns by the types of PostgreSQL" do
          expected = [
            {name: "id", type: "integer", constraints: {required: true}},
            {name: "code", type: "string"},
            {name: "doc", type: "any"},
            {name: "ints", type: "array"},
            {name: "words", type: "array"},
            {name: "total", type: "number"},
            {name: "price", type: "number", decimals: 3},
            {name: "cost", type: "number", decimals: 2},
            {name: "wait", type: "any"},
            {name: "host", type: "string"},
            {name: "mac", type: "string"},
            {name: "seen", type: "datetime"},
            {name: "opens", type: "any"},
            {name: "blob", type: "any"},
            {name: "feeling", type: "string"},
            {name: "whole", type: "integer"},
            {name: "network", type: "string"},
            {name: "address", type: "string"}
          ]

          assert_equal expected, IOStreams.stream(model.all).schema[:fields]
        end

        it "reads the values as pluck does, but an address as the text that PostgreSQL returns, with its prefix" do
          names     = model.column_names
          plucked   = names.zip(model.pluck(*names).first).to_h
          record    = each(IOStreams.stream(model.all)).first
          addresses = %w[host network address]

          assert_equal plucked.except(*addresses), record.except(*addresses)
          assert_equal IPAddr.new("192.168.0.1"), plucked["host"]
          assert_equal "192.168.0.1", record["host"]
          assert_equal "10.0.0.0/8", record["network"]
          assert_equal "192.168.1.5/24", record["address"]
          assert_equal({"a" => [1, 2]}, record["doc"])
          assert_equal ["x", "y z"], record["words"]
          assert_equal BigDecimal("12.345678"), record["total"]
          assert_equal BigDecimal("9.99"), record["cost"]
          assert_equal Time.utc(2026, 10, 20, 10, 30), record["seen"]
          assert_equal 42, record["whole"]
        end

        it "types computed columns by the types of the result" do
          relation = db.order.select("SUM(amount) AS total, COUNT(*) AS orders, MAX(shipped_on) AS latest")
          stream   = IOStreams.stream(relation)

          assert_equal [{name: "total", type: "number"}, {name: "orders", type: "integer"}, {name: "latest", type: "date"}],
                       stream.schema[:fields]
          assert_equal [{"total" => BigDecimal("115.75"), "orders" => 3, "latest" => Date.new(2026, 10, 1)}], each(stream)
        end
      end
    end
  end

  describe ".failure_kind" do
    it "returns the kind of failure of an exception of the pg gem" do
      skip "The pg gem is a C extension, which JRuby cannot load" unless QueryDatabase.driver?("pg")

      assert_equal IOStreams::Errors::PermissionDenied,
                   IOStreams::Query::PostgresqlCursor.failure_kind(PG::InsufficientPrivilege.new("denied"))
      assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::PostgresqlCursor.failure_kind(PG::AdminShutdown.new("shutdown"))
      assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::PostgresqlCursor.failure_kind(PG::UnableToSend.new("lost"))
      {
        "FATAL:  sorry, too many clients already"                                     => IOStreams::Errors::Unavailable,
        "FATAL:  the database system is starting up"                                  => IOStreams::Errors::Unavailable,
        "could not translate host name \"db\" to address: Temporary failure in name resolution" =>
          IOStreams::Errors::Unavailable,
        "FATAL:  password authentication failed for user \"jack\""                    => IOStreams::Errors::PermissionDenied,
        "FATAL:  no pg_hba.conf entry for host \"10.0.0.1\", user \"jack\""          => IOStreams::Errors::PermissionDenied,
        "could not translate host name \"db\" to address: Name or service not known"  => nil,
        "FATAL:  database \"missing\" does not exist"                                 => nil
      }.each_pair do |message, kind|
        actual = IOStreams::Query::PostgresqlCursor.failure_kind(PG::ConnectionBad.new(message))

        kind ? assert_equal(kind, actual, message) : assert_nil(actual, message)
      end

      assert_nil IOStreams::Query::PostgresqlCursor.failure_kind(PG::UndefinedTable.new("no table"))
      assert_nil IOStreams::Query::PostgresqlCursor.failure_kind(RuntimeError.new("other"))
    end
  end
end
