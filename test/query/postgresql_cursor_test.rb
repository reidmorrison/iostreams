# frozen_string_literal: true

require_relative "query_helper"
require "timeout"

# Reads a query on PostgreSQL with a cursor, see `IOStreams::Query::PostgresqlCursor`, when POSTGRES_URL is set, or on
# JRuby with the PostgreSQL adapter of AR-JDBC, see `IOStreams::Query::PostgresqlJdbc`, apart from what differs with its
# driver, PgJDBC: what it raises, and some of the values that it returns.
class PostgresqlCursorTest < Minitest::Test
  if (database = QueryDatabase.find("PostgreSQL"))
    describe(QueryDatabase.jdbc? ? IOStreams::Query::PostgresqlJdbc : IOStreams::Query::PostgresqlCursor) do
      include QueryTestMethods

      let(:db) { database }
      let(:jdbc) { QueryDatabase.jdbc? }

      # Returns [Class] the supplied exception that Active Record raises for a connection that could not be made, or on
      # JRuby the one that AR-JDBC raises for it, as for every error of its driver.
      def connection_error(error_class = ActiveRecord::ConnectionNotEstablished)
        jdbc ? ActiveRecord::JDBCError : error_class
      end
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

      it "reads a connection to PostgreSQL, or on JRuby one of the PostgreSQL adapter of AR-JDBC" do
        db.record.with_connection do |connection|
          assert_equal !jdbc, IOStreams::Query::PostgresqlCursor.reads?(connection)
          assert_equal jdbc, IOStreams::Query::PostgresqlJdbc.reads?(connection)
        end
      end

      # Returns [Array<Integer>] the number of rows that each fetch of a cursor asks for within the block.
      def fetch_sizes(&)
        sql      = []
        callback = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] if payload[:name] == "IOStreams Fetch" }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &)
        sql.map { |text| Integer(text[/\AFETCH FORWARD (\d+) /, 1]) }
      end

      it "fetches the rows of one query, FIRST_FETCH, then MAX_FETCH at a time, since they are narrow" do
        add_orders(25_000)
        count = 0
        sizes = fetch_sizes do
          names = statements { IOStreams.stream(orders).each(:hash) { |_order| count += 1 } }

          assert_equal 1, names.count("IOStreams Columns")
        end

        assert_equal 25_003, count
        assert_equal [100, 10_000, 10_000, 10_000], sizes
      end

      it "fetches as many rows as hold about FETCH_BYTES of their values, once the first fetch shows how wide they are" do
        add_orders(300)
        # Rows of about 100 KB, which the query computes, so that the table stays small.
        relation = orders.select("id, repeat(md5(id::text), 3125) AS wide")
        count    = 0
        sizes    = fetch_sizes { IOStreams.stream(relation).each(:hash) { |_order| count += 1 } }
        each_row = 100_000 + IOStreams::Query::PostgresqlCursor::VALUE_BYTES

        assert_equal 303, count
        assert_equal IOStreams::Query::PostgresqlCursor::FETCH_BYTES / each_row, sizes[1]
        assert_equal [100, 83, 83, 83], sizes
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

      # Returns [Array<String>] the SQL of each statement of the settings of a cursor that runs within the block.
      def settings_statements(&)
        sql      = []
        callback = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] if payload[:name] == "IOStreams" }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &)
        sql.grep(/set_config|current_setting/)
      end

      it "sets idle_in_transaction_session_timeout on PostgreSQL 9.6 and later, and transaction_timeout on 17 and later" do
        pinned do
          db.record.with_connection do |connection|
            [[90_500, false, false], [90_600, true, false], [170_000, true, true]].each do |version, idle, transaction|
              sql = connection.stub(:database_version, version) do
                settings_statements { assert_equal 3, each(IOStreams.stream(orders)).size }
              end

              # It reads the settings of the transaction that is open, sets them, and sets them back.
              assert_equal 3, sql.size, version
              assert_equal [true] * 3, sql.map { |text| text.include?("cursor_tuple_fraction") }, version
              assert_equal [idle] * 3, sql.map { |text| text.include?("idle_in_transaction_session_timeout") }, version
              assert_equal [transaction] * 3, sql.map { |text| text.include?("'transaction_timeout'") }, version
            end
          end
        end
      end

      it "reads for longer than the transaction_timeout of the connection, on PostgreSQL 17 and later" do
        skip "PostgreSQL has transaction_timeout from 17" if db.record.with_connection(&:database_version) < 170_000

        names = []
        IOStreams.stream(orders_with("Transaction", transaction_timeout: 500).order(:id)).each(:hash) do |order|
          sleep(0.3)
          names << order["name"]
        end

        assert_equal %w[a b c], names
      end

      it "applies the statement_timeout of the connection to each fetch, rather than to the whole query" do
        add_orders(25_000)
        count = 0
        IOStreams.stream(orders_with("Timeout", statement_timeout: 500).order(:id)).each(:hash) do |_order|
          sleep(0.3) if (count % IOStreams::Query::PostgresqlCursor::MAX_FETCH).zero?
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

      it "raises a failure to close the cursor once the block breaks out of the loop, tagged, rather than return" do
        error = assert_raises(ActiveRecord::ActiveRecordError) do
          with_read_connections do |connections|
            IOStreams.stream(orders).each(:hash) do |_order| # rubocop:disable Lint/UnreachableLoop -- leaves on its first row on purpose
              # The server ends the connection of the read while the block runs.
              execute("SELECT pg_terminate_backend(#{connections.last.select_value('SELECT pg_backend_pid()')})")
              break
            end
          end
        end

        assert_kind_of IOStreams::Errors::Unavailable, error
        assert_equal 0, db.pool.stat[:busy]
      end

      # Returns [ActiveRecord::Relation] the orders of the model, whose last row takes the supplied number of seconds to
      # read, which is after the first fetch, of FIRST_FETCH rows.
      def slow_last_row(model, seconds)
        add_orders(IOStreams::Query::PostgresqlCursor::FIRST_FETCH)
        last = model.maximum(:id)
        model.order(:id).select("id, CASE WHEN id = #{last} THEN pg_sleep(#{seconds})::text END AS slept")
      end

      it "ends a read that is interrupted while it fetches, at once, rather than once the fetch finishes" do
        skip "PgJDBC blocks in Java while it fetches, which a Timeout interrupts once the fetch returns" if jdbc
        stream = IOStreams.stream(slow_last_row(db.order, 4))
        stream.infer_schema
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(Timeout::Error) { Timeout.timeout(1.5) { each(stream) } }

        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
        assert_equal 0, db.pool.stat[:busy]
        assert_equal 3, each(IOStreams.stream(orders.limit(3))).size
      end

      it "neither closes the cursor nor sets back the settings after a fetch fails, which aborts the transaction" do
        model    = orders_with("Canceled", statement_timeout: 500)
        relation = slow_last_row(model, 2)
        sql      = []
        callback = ->(_name, _start, _finish, _id, payload) { sql << payload[:sql] }
        error    = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          assert_raises(ActiveRecord::QueryCanceled) { each(IOStreams.stream(relation)) }
        end

        assert_kind_of IOStreams::Errors::Unavailable, error
        assert_includes sql, "ROLLBACK"
        assert_empty(sql.grep(/\ACLOSE /))
      end

      it "commits the writes of the block on their own, which a failure of a statement of the block does not undo" do
        names = []
        IOStreams.stream(orders).each(:hash) do |order|
          db.customer.create!(name: "for #{order['name']}")
          begin
            db.customer.create!(id: db.customer.minimum(:id), name: "duplicate")
          rescue ActiveRecord::RecordNotUnique
            # Rescued by the block, which goes on.
          end
          names << order["name"]
        end

        assert_equal %w[a b c], names
        assert_equal ["for a", "for b", "for c"], db.customer.where("name LIKE 'for %'").order(:id).pluck(:name)
      end

      it "keeps the writes of the block for the rows before one that raises" do
        assert_raises(RuntimeError) do
          IOStreams.stream(orders).each(:hash) do |order|
            raise "stop" if order["name"] == "c"

            db.customer.create!(name: "kept #{order['name']}")
          end
        end

        assert_equal ["kept a", "kept b"], db.customer.where("name LIKE 'kept %'").order(:id).pluck(:name)
      end

      it "raises an ActiveRecord::Rollback of the block, which rolls back the transaction of the caller" do
        db.record.transaction do
          db.customer.create!(name: "before")
          IOStreams.stream(orders).each(:hash) { |order| raise ActiveRecord::Rollback if order["name"] == "b" }
          db.customer.create!(name: "after")
        end

        assert_equal %w[Acme Globex], db.customer.order(:id).pluck(:name)
        assert_raises(ActiveRecord::Rollback) do
          IOStreams.stream(orders).each(:hash) { |_order| raise ActiveRecord::Rollback } # rubocop:disable Lint/UnreachableLoop -- raises on its first row on purpose
        end
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
        stream.infer_schema
        pinned do
          execute("SET LOCAL statement_timeout = '100ms'")
          error = assert_raises(ActiveRecord::QueryCanceled) { each(stream) }

          assert_kind_of IOStreams::Errors::Unavailable, error
          driver = jdbc ? "ActiveRecord::JDBCError: org.postgresql.util.PSQLException: ERROR: " : "PG::QueryCanceled: ERROR:  "

          assert_match(/\A#{db.order.name} query: #{driver}canceling statement due to statement timeout/, error.message)
          assert_equal 3, db.order.count
        end
      end

      # Returns [String] the name of the role of this process, which may not log in, nor read the tables, see
      # QueryDatabase::PostgresqlSchema.role.
      def role
        db.record.with_connection { |connection| QueryDatabase::PostgresqlSchema.role(connection) }
      end

      it "tags a table that the user may not read as PermissionDenied" do
        reader = db.record.with_connection { |connection| connection.quote_column_name(role) }
        stream = IOStreams.stream(orders)
        stream.infer_schema
        pinned do
          execute("SET LOCAL ROLE #{reader}")
          error = assert_raises(ActiveRecord::StatementInvalid) { each(stream) }

          assert_kind_of IOStreams::Errors::PermissionDenied, error
          assert_match(/permission denied for table orders/, error.message)
        end
      end

      # Returns [Class] a model of the orders table on a connection to the url of POSTGRES_URL, changed by the block.
      def orders_at(name)
        url = URI(QueryDatabase::PostgresqlSchema.url)
        yield url
        orders_on(name, url: url.to_s)
      end

      # Returns [Class] a model of the orders table on a connection of the supplied configuration.
      def orders_on(name, config)
        record = Class.new(ActiveRecord::Base) { self.abstract_class = true }
        constant = :"#{name}Record"
        QueryDatabase::PostgreSQL.send(:remove_const, constant) if QueryDatabase::PostgreSQL.const_defined?(constant)
        QueryDatabase::PostgreSQL.const_set(constant, record)
        record.establish_connection(pool: 1, connect_timeout: 2, **config)
        Class.new(record) { self.table_name = "orders" }
      end

      # Returns [Class] a model of the orders table, on a pool of one connection of its own, whose connections set the
      # supplied variables, such as `statement_timeout`, as the `variables` of the configuration of a database do.
      def orders_with(name, variables)
        orders_on(name, db.record.connection_db_config.configuration_hash.except(:pool).merge(variables: variables))
      end

      it "tags a server that refuses the connection as Unavailable" do
        orders = orders_at("Refused") { |url| url.port = 1 }
        error  = assert_raises(connection_error) { each(IOStreams.stream(orders.all)) }

        assert_kind_of IOStreams::Errors::Unavailable, error
        # As libpq says it, "Connection refused", or PgJDBC, "Connection to localhost:1 refused".
        assert_match(/Connection (?:to \S+ )?refused/, error.cause.message)
      end

      it "tags a password that the server rejects as PermissionDenied" do
        orders = orders_at("Rejected") { |url| url.password = "wrong" }
        error  = assert_raises(connection_error) { each(IOStreams.stream(orders.all)) }

        assert_kind_of IOStreams::Errors::PermissionDenied, error
      end

      it "does not tag a connection that requires TLS of a server without it, which a retry does not change" do
        skip "The server supports TLS" if db.record.with_connection { |connection| connection.select_value("SHOW ssl") } == "on"

        orders = orders_at("Plain") { |url| url.query = "sslmode=require" }
        error  = assert_raises(connection_error) { each(IOStreams.stream(orders.all)) }

        refute_kind_of IOStreams::Errors::StorageError, error
        # As PgJDBC says it, or libpq, whose message Active Record names as one of the host.
        assert_match(/does not support SSL/, jdbc ? error.message : error.cause.message)
      end

      it "does not tag a host that does not resolve" do
        orders = orders_at("Unknown") { |url| url.host = "iostreams-no-such-host.invalid" }
        error  = assert_raises(connection_error) { each(IOStreams.stream(orders.all)) }

        refute_kind_of IOStreams::Errors::StorageError, error
      end

      # Active Record names a connection that could not be made by what the message of libpq includes: any failure for
      # the database postgres as a connection that could not be established, one whose message includes the name of the
      # database as a database that does not exist, and one whose message includes the name of the user as a user name
      # or password that the server rejects.

      it "does not tag a host that does not resolve, which Active Record names as credentials when it includes the user" do
        skip "AR-JDBC does not name a connection that could not be made by the message of its driver" if jdbc
        orders = orders_at("UnknownOfUser") do |url|
          # Setting the host clears the user.
          url.host = "iostreams-db.invalid"
          url.user = "iostreams"
        end
        error = assert_raises(ActiveRecord::DatabaseConnectionError) { each(IOStreams.stream(orders.all)) }

        assert_match(%r{username/password}, error.message)
        refute_kind_of IOStreams::Errors::StorageError, error
      end

      it "does not tag a host that does not resolve, which Active Record does not name for the database postgres" do
        skip "AR-JDBC does not name a connection that could not be made by the message of its driver" if jdbc
        orders = orders_at("UnknownOfPostgres") do |url|
          url.host = "iostreams-no-such-host.invalid"
          url.path = "/postgres"
        end
        error = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(orders.all)) }

        assert_match(/could not translate host name/, error.message)
        refute_kind_of IOStreams::Errors::StorageError, error
      end

      it "does not tag a database that does not exist on the last address that it tried, after one that refused it" do
        url = URI(QueryDatabase::PostgresqlSchema.url)
        skip "POSTGRES_URL names no host" if url.host.to_s.empty?
        skip "AR-JDBC does not connect to a list of hosts, as libpq does" if jdbc

        orders = orders_on(
          "Retried",
          adapter: "postgresql", host: "#{url.host},#{url.host}", port: "1,#{url.port || 5432}",
          username: url.user && URI.decode_uri_component(url.user),
          password: url.password && URI.decode_uri_component(url.password), database: "iostreams_no_such_database"
        )
        error = assert_raises(ActiveRecord::NoDatabaseError) { each(IOStreams.stream(orders.all)) }

        assert_match(/Connection refused.*database "iostreams_no_such_database" does not exist/m, error.cause.message)
        refute_kind_of IOStreams::Errors::StorageError, error
      end

      it "tags a role that may not log in as PermissionDenied, whatever Active Record names it" do
        name  = role
        named = {
          "postgres"                                    => ActiveRecord::ConnectionNotEstablished,
          # The name of the role starts with that of the database.
          db.record.with_connection(&:current_database) => ActiveRecord::NoDatabaseError
        }
        named.each_pair do |database, error_class|
          orders = orders_at("NotPermitted") do |url|
            url.user     = name
            url.password = QueryDatabase::PostgresqlSchema::PASSWORD
            url.path     = "/#{database}"
          end
          error = assert_raises(jdbc ? ActiveRecord::StatementInvalid : error_class) { each(IOStreams.stream(orders.all)) }

          assert_instance_of error_class, error unless jdbc

          assert_kind_of IOStreams::Errors::PermissionDenied, error, database
          assert_match(/role "#{name}" is not permitted to log in/, error.cause.message)
        end
      end

      it "reads the rows of each batch in the order of the primary key, after updates move them" do
        add_orders(3_000)
        execute("UPDATE orders SET name = name || '!' WHERE id % 3 = 0")
        ids = each(IOStreams.stream(db.order.select(:id).in_batches(of: 2_000))).map { |order| order["id"] }

        assert_equal 3_003, ids.size
        assert_equal ids.sort, ids
      end

      it "requires a column that is never null, of a type that always has a value on PostgreSQL, such as an array" do
        execute("DROP TABLE IF EXISTS pg_required")
        execute(<<~SQL)
          CREATE TABLE pg_required (id bigserial PRIMARY KEY, tags text[] NOT NULL, starts date NOT NULL, note text NOT NULL)
        SQL
        execute("INSERT INTO pg_required (tags, starts, note) VALUES ('{}', '2026-10-21', '')")
        model = Class.new(db.record) { self.table_name = "pg_required" }

        assert_equal [{name: "id", type: "integer", constraints: {required: true}},
                      {name: "tags", type: "array", constraints: {required: true}},
                      {name: "starts", type: "date", constraints: {required: true}}, {name: "note", type: "string"}],
                     IOStreams.stream(model.all).infer_schema.to_h[:fields]
        assert_equal [{"tags" => [], "starts" => Date.new(2026, 10, 21), "note" => ""}],
                     each(IOStreams.stream(model.select(:tags, :starts, :note)))
      ensure
        execute("DROP TABLE IF EXISTS pg_required")
      end

      it "does not clear the query cache of the application" do
        db.record.cache do
          db.order.first
          db.customer.first

          assert_equal 3, each(IOStreams.stream(orders)).size
          assert_equal 2, db.pool.query_cache.size
        end
      end

      it "clears the query cache of the application when a read in a transaction of its own fails, which Active Record " \
         "rolls back" do
        db.record.cache do
          db.order.first
          db.customer.first
          stream = IOStreams.stream(db.order.select("1 / (id - id) AS ratio"))

          assert_raises(ActiveRecord::StatementInvalid) { each(stream) }
          assert_equal 0, db.pool.query_cache.size
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
              blob bytea, feeling mood, whole numeric(10, 0), network cidr, address inet, closes timetz
            )
          SQL
          execute(<<~SQL)
            INSERT INTO pg_types (code, doc, ints, words, total, price, cost, wait, host, mac, seen, opens, blob, feeling, whole,
                                  network, address, closes)
            VALUES ('9b3e9a64-4b7a-4b4e-9e8e-2f1d7c1a6b55', '{"a": [1, 2]}', '{1,2}', '{x,"y z"}', 12.345678, 1.5, 9.99,
                    '1 mon 1 day 2 hours', '192.168.0.1', '08:00:2b:01:02:03', '2026-10-20 12:30:00+02', '09:15', '\\x0102',
                    'happy', 42, '10.0.0.0/8', '192.168.1.5/24', '17:00:00+02')
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
            {name: "wait", type: "duration"},
            {name: "host", type: "string"},
            {name: "mac", type: "string"},
            {name: "seen", type: "datetime"},
            {name: "opens", type: "time"},
            {name: "blob", type: "any"},
            {name: "feeling", type: "string"},
            {name: "whole", type: "integer"},
            {name: "network", type: "string"},
            {name: "address", type: "string"},
            # A timetz, which Active Record does not know, so that PostgreSQL returns its text, which AR-JDBC casts to a
            # Time, and whose results have no types, see #unknown_type.
            {name: "closes", type: jdbc ? "any" : "string"}
          ]

          assert_equal expected, IOStreams.stream(model.all).infer_schema.to_h[:fields]
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
          assert_equal({months: 1, days: 1, hours: 2}, record["wait"].parts)
          # 09:15 UTC, which Active Record reads in the time zone of the app.
          assert_equal Time.new(2000, 1, 1, 4, 15, 0, "-05:00"), record["opens"]
          # AR-JDBC casts a timetz to a Time of UTC, without its offset, as pluck returns it on JRuby.
          assert_equal (jdbc ? Time.utc(2000, 1, 1, 17) : "17:00:00+02"), record["closes"]
        end

        it "reads an interval of its slices as a duration, also once a store keeps its seconds, as BSON does" do
          relation = model.select(:id, :wait)
          slices   = []
          IOStreams.stream(relation).each(:slice, size: 5) { |slice| slices << slice }
          hash     = slices.first.to_h
          # BSON keeps an ActiveSupport::Duration as its number of seconds.
          stored   = IOStreams.slice(hash.merge("rows" => hash["rows"].map { |id, wait| [id, wait.to_i] }))
          records  = []
          IOStreams.stream(stored).schema(IOStreams.stream(relation).schema).each(:hash) { |record| records << record }

          assert_predicate stored, :typed?
          assert_instance_of ActiveSupport::Duration, records.first["wait"]
          assert_equal({months: 1, days: 1, hours: 2}, records.first["wait"].parts)
        end

        it "keeps the values that pg casts of columns that Active Record casts as they are, but whose types it knows" do
          unless QueryDatabase::PostgreSQL.const_defined?(:PgScored)
            QueryDatabase::PostgreSQL.const_set(:PgScored, Class.new(db.record) do
              self.table_name = "pg_types"
              attribute :score
            end)
          end
          scored = QueryDatabase::PostgreSQL::PgScored
          # A column of a common table expression, which Active Record casts by the table of no model, and an attribute
          # without a type, both of which return the value that the driver casts.
          cte    = model.with(t: model.select(:id, "whole AS n", "seen AS at")).joins("JOIN t ON t.id = pg_types.id")
          stream = IOStreams.stream(cte.select("pg_types.id", "t.n", "t.at"))

          assert_equal [{name: "id", type: "integer"}, {name: "n", type: "any"}, {name: "at", type: "any"}], stream.infer_schema.to_h[:fields]
          assert_equal [{"id" => model.first.id, "n" => 42, "at" => Time.utc(2026, 10, 20, 10, 30)}], each(stream)
          stream = IOStreams.stream(scored.select("whole * 2 AS score"))

          assert_equal [{name: "score", type: "any"}], stream.infer_schema.to_h[:fields]
          assert_equal [{"score" => 84}], each(stream)
        end

        it "copies a time of day, an interval and a timetz to CSV, and to Parquet, which they raised for as any" do
          relation = model.select(:opens, :wait, :closes)
          csv      = StringIO.new
          IOStreams.stream(csv).format(:csv).copy_from(relation, mode: :hash)

          closes = jdbc ? "2000-01-01T17:00:00Z" : "17:00:00+02"

          assert_equal "opens,wait,closes\n04:15:00,P1M1DT2H,#{closes}\n", csv.string
          skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "types.parquet")
            path.copy_from(relation, mode: :hash)
            record = each(path.schema(IOStreams.stream(relation).schema)).first

            assert_equal Time.utc(2000, 1, 1, 4, 15), record["opens"]
            assert_equal({months: 1, days: 1, hours: 2}, record["wait"].parts)
            assert_equal "17:00:00+02", record["closes"]
          end
        end

        it "requires a time and an interval that are never null" do
          execute("ALTER TABLE pg_types ALTER COLUMN opens SET NOT NULL, ALTER COLUMN wait SET NOT NULL")
          model.reset_column_information

          # An interval is not required on JRuby, since AR-JDBC returns a zero one as text that Active Record casts to nil.
          wait = jdbc ? {name: "wait", type: "duration"} : {name: "wait", type: "duration", constraints: {required: true}}

          assert_equal(
            [{name: "opens", type: "time", constraints: {required: true}}, wait],
            IOStreams.stream(model.select(:opens, :wait)).infer_schema.to_h[:fields]
          )
        end

        it "reads an interval that is zero or infinite as nil on JRuby, as pluck does, since AR-JDBC returns both as P" do
          skip "Only JRuby reads PostgreSQL with AR-JDBC" unless jdbc

          intervals = ["0 seconds"]
          intervals << "infinity" if db.record.with_connection(&:database_version) >= 170_000
          intervals.each do |interval|
            execute("UPDATE pg_types SET wait = '#{interval}'")

            assert_nil model.pluck(:wait).first, interval
            assert_equal [{"id" => model.first.id, "wait" => nil}], each(IOStreams.stream(model.select(:id, :wait))), interval
          end
        end

        it "raises for an infinite interval, which Active Record reads as nil, whether or not it can be null" do
          skip "An interval is infinite only from PostgreSQL 17" if db.record.with_connection(&:database_version) < 170_000
          skip "AR-JDBC returns an infinite interval as it returns a zero one, see above" if jdbc

          %w[infinity -infinity].each do |infinite|
            execute("UPDATE pg_types SET wait = '#{infinite}'")

            assert_nil model.pluck(:wait).first
            error = assert_raises(IOStreams::Errors::InvalidValue, infinite) { each(IOStreams.stream(model.select(:id, :wait))) }
            assert_equal "Column \"wait\": #{infinite.inspect} is an infinite interval, which a duration field cannot hold, " \
                         "and Active Record reads as nil, so select it as null when it is not finite, or as text, instead",
                         error.message
            assert_raises(IOStreams::Errors::InvalidValue, infinite) do
              each(IOStreams.stream(model.select(:id, :wait).in_batches))
            end
          end
          execute("ALTER TABLE pg_types ALTER COLUMN wait SET NOT NULL")
          model.reset_column_information

          assert_raises(IOStreams::Errors::InvalidValue) { each(IOStreams.stream(model.select(:id, :wait))) }
          finite = model.select(:id, Arel.sql("CASE WHEN isfinite(wait) THEN wait END AS wait"))

          assert_equal [{"id" => model.first.id, "wait" => nil}], each(IOStreams.stream(finite))
        end

        it "raises for a time of 24:00:00, which PostgreSQL holds, rather than read it as the start of the next day" do
          skip "AR-JDBC raises for it itself, see below" if jdbc
          execute("UPDATE pg_types SET opens = '24:00:00'")

          error = assert_raises(IOStreams::Errors::InvalidValue) { each(IOStreams.stream(model.select(:id, :opens))) }
          assert_equal 'Column "opens": "24:00:00" is not a time of day, from 00:00:00 to 23:59:59, which a time field ' \
                       "holds, so select it as text, or as a number of seconds, instead", error.message
          assert_raises(IOStreams::Errors::InvalidValue) { each(IOStreams.stream(model.select(:id, :opens).in_batches)) }
        end

        # With an exception of Joda-Time, which it casts a time with, as pluck does on JRuby.
        it "raises on JRuby for a time of 24:00:00, as AR-JDBC does" do
          skip "Only JRuby reads PostgreSQL with AR-JDBC" unless jdbc
          execute("UPDATE pg_types SET opens = '24:00:00'")

          [model.select(:id, :opens), model.select(:id, :opens).in_batches].each do |relation|
            error = assert_raises(StandardError, Java::JavaLang::RuntimeException) { each(IOStreams.stream(relation)) }
            assert_match(/Value 24 for hourOfDay must be in the range/, error.message)
          end
        end

        it "types computed columns by the types of the result" do
          relation = db.order.select("SUM(amount) AS total, COUNT(*) AS orders, MAX(shipped_on) AS latest")
          stream   = IOStreams.stream(relation)

          # The results of AR-JDBC have no types, so the computed columns are of any type, whose values its driver casts.
          types = jdbc ? %w[any any any] : %w[number integer date]

          assert_equal(%w[total orders latest].zip(types).map { |name, type| {name: name, type: type} }, stream.infer_schema.to_h[:fields])
          assert_equal [{"total" => BigDecimal("115.75"), "orders" => 3, "latest" => Date.new(2026, 10, 1)}], each(stream)
        end
      end

      describe "the types of PostgreSQL that Active Record decorates" do
        # A model whose array of times is in the time zone of the application, which Active Record decorates, as it
        # decorates an attribute that is normalized.
        let(:model) do
          unless QueryDatabase::PostgreSQL.const_defined?(:PgDecorated)
            QueryDatabase::PostgreSQL.const_set(:PgDecorated, Class.new(db.record) do
              self.table_name = "pg_decorated"
              normalizes :labels, with: ->(labels) { labels.map(&:strip) }
              normalizes :address, with: ->(address) { address }
            end)
          end
          QueryDatabase::PostgreSQL::PgDecorated
        end

        before do
          execute("DROP TABLE IF EXISTS pg_decorated")
          execute(<<~SQL)
            CREATE TABLE pg_decorated (
              id bigserial PRIMARY KEY, reminders timestamp[], labels text[], hosts inet[], networks cidr[], address inet
            )
          SQL
          execute(<<~SQL)
            INSERT INTO pg_decorated (reminders, labels, hosts, networks, address)
            VALUES ('{"2026-10-20 12:30:00","2026-10-21 08:00:00"}', '{"a ","b"}', '{10.0.0.0/8,192.168.1.5/24}',
                    '{10.0.0.0/8,192.168.1.0/24}', '192.168.1.5/24')
          SQL
          model.reset_column_information
        end

        after { execute("DROP TABLE IF EXISTS pg_decorated") }

        it "reads an array of times in the time zone of the application, or one that is normalized, as an array" do
          relation = model.select(:reminders, :labels)
          record   = each(IOStreams.stream(relation)).first

          assert_equal [{name: "reminders", type: "array"}, {name: "labels", type: "array"}],
                       IOStreams.stream(relation).infer_schema.to_h[:fields]
          assert_equal relation.pluck(:reminders, :labels).first, record.values_at("reminders", "labels")
          assert_equal [ActiveSupport::TimeWithZone], record["reminders"].map(&:class).uniq
          assert_equal Time.utc(2026, 10, 20, 12, 30), record["reminders"].first
          assert_equal ["a ", "b"], record["labels"]
        end

        it "reads an array of addresses, and one that is normalized, as the text that PostgreSQL returns, with its host" do
          relation = model.select(:hosts, :networks, :address)
          record   = each(IOStreams.stream(relation)).first

          assert_equal [{name: "hosts", type: "array"}, {name: "networks", type: "array"}, {name: "address", type: "string"}],
                       IOStreams.stream(relation).infer_schema.to_h[:fields]
          assert_equal({"hosts" => %w[10.0.0.0/8 192.168.1.5/24], "networks" => %w[10.0.0.0/8 192.168.1.0/24],
                        "address" => "192.168.1.5/24"}, record)

          csv = StringIO.new
          IOStreams.stream(csv).format(:csv).copy_from(relation, mode: :hash)

          assert_equal <<~CSV, csv.string
            hosts,networks,address
            "[""10.0.0.0/8"",""192.168.1.5/24""]","[""10.0.0.0/8"",""192.168.1.0/24""]",192.168.1.5/24
          CSV
        end

        it "copies an array of times in the time zone of the application, or one that is normalized, to CSV and JSON" do
          relation = model.select(:reminders, :labels)
          csv      = StringIO.new
          json     = StringIO.new
          IOStreams.stream(csv).format(:csv).copy_from(relation, mode: :hash)
          IOStreams.stream(json).format(:json).copy_from(relation, mode: :hash)
          schema   = IOStreams.stream(relation).infer_schema
          records  = [[csv, :csv], [json, :json]].map do |output, format|
            each(IOStreams.stream(StringIO.new(output.string)).format(format).schema(schema)).first
          end

          records.each do |record|
            assert_equal %w[2026-10-20T08:30:00-04:00 2026-10-21T04:00:00-04:00], record["reminders"]
            assert_equal ["a ", "b"], record["labels"]
          end
        end
      end
    end
  end

  describe ".reads?" do
    # Returns [true|false] whether a connection through the adapter of the supplied name is read.
    def reads?(adapter_name)
      IOStreams::Query::PostgresqlCursor.reads?(Struct.new(:adapter_name).new(adapter_name))
    end

    it "reads PostgreSQL, and PostGIS, which adds the types of its extension to it" do
      assert reads?("PostgreSQL")
      assert reads?("PostGIS")
    end

    it "does not read any other adapter, such as that of CockroachDB, which subclasses that of PostgreSQL" do
      refute reads?("CockroachDB")
      refute reads?("SQLite")
      refute reads?("Mysql2")
    end
  end

  describe ".failure_kind" do
    before { skip "The pg gem is a C extension, which JRuby cannot load" unless QueryDatabase.driver?("pg") }

    # Asserts that a connection that failed with each message of libpq is the supplied kind of failure.
    def assert_connection_kind(kind, messages)
      messages.each do |message|
        actual = IOStreams::Query::PostgresqlCursor.failure_kind(PG::ConnectionBad.new(message))

        kind ? assert_equal(kind, actual, message) : assert_nil(actual, message)
      end
    end

    it "returns the kind of failure of an exception of the pg gem that a statement raises" do
      assert_equal IOStreams::Errors::PermissionDenied,
                   IOStreams::Query::PostgresqlCursor.failure_kind(PG::InsufficientPrivilege.new("denied"))
      assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::PostgresqlCursor.failure_kind(PG::AdminShutdown.new("shutdown"))
      assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::PostgresqlCursor.failure_kind(PG::UnableToSend.new("lost"))
      assert_equal IOStreams::Errors::Unavailable,
                   IOStreams::Query::PostgresqlCursor.failure_kind(PG::IdleInTransactionSessionTimeout.new("idle"))
      assert_nil IOStreams::Query::PostgresqlCursor.failure_kind(PG::UndefinedTable.new("no table"))
      assert_nil IOStreams::Query::PostgresqlCursor.failure_kind(RuntimeError.new("other"))
    end

    # The messages of the connections below are those that libpq reported against PostgreSQL 17: libpq 18 on macOS,
    # libpq 17 and 18 on Linux, with glibc and with musl, and libpq 13, whose messages have the format of before 14.

    it "returns PermissionDenied for credentials, or a host, that the server does not accept, by any method" do
      assert_connection_kind(
        IOStreams::Errors::PermissionDenied,
        [
          "connection to server at \"127.0.0.1\", port 55432 failed: FATAL:  password authentication failed for user " \
          "\"postgres\"\n",
          "connection to server at \"127.0.0.1\", port 55432 failed: fe_sendauth: no password supplied\n",
          "connection to server at \"127.0.0.1\", port 55498 failed: FATAL:  Ident authentication failed for user " \
          "\"iostreams_fix_qp_ident\"\n",
          "connection to server on socket \"/var/run/postgresql/.s.PGSQL.5432\" failed: FATAL:  Peer authentication " \
          "failed for user \"iostreams_fix_qp_peer\"\n",
          "connection to server at \"127.0.0.1\", port 55498 failed: FATAL:  PAM authentication failed for user " \
          "\"iostreams_fix_qp_pam\"\n",
          "connection to server at \"127.0.0.1\", port 55498 failed: FATAL:  LDAP authentication failed for user " \
          "\"iostreams_fix_qp_ldap\"\n",
          "connection to server at \"127.0.0.1\", port 55498 failed: FATAL:  RADIUS authentication failed for user " \
          "\"iostreams_fix_qp_radius\"\n",
          "connection to server at \"127.0.0.1\", port 55498 failed: FATAL:  connection requires a valid client " \
          "certificate\n",
          "connection to server at \"127.0.0.1\", port 55498 failed: FATAL:  certificate authentication failed for user " \
          "\"iostreams_fix_qp_cert\"\n",
          # The messages of PostgreSQL for GSSAPI and SSPI, which were not run.
          "connection to server at \"127.0.0.1\", port 5432 failed: FATAL:  GSSAPI authentication failed for user " \
          "\"jack\"\n",
          "connection to server at \"127.0.0.1\", port 5432 failed: FATAL:  SSPI authentication failed for user \"jack\"\n",
          "connection to server at \"127.0.0.1\", port 55498 failed: FATAL:  pg_hba.conf rejects connection for host " \
          "\"172.17.0.1\", user \"iostreams_fix_qp_reject\", database \"app\", no encryption\n",
          "FATAL:  no pg_hba.conf entry for host \"10.0.0.1\", user \"jack\"",
          "connection to server at \"127.0.0.1\", port 55432 failed: FATAL:  role \"iostreams_fix_qp_nologin\" is not " \
          "permitted to log in\n",
          "connection to server at \"127.0.0.1\", port 55432 failed: FATAL:  permission denied for database " \
          "\"iostreams_fix_qp_noconnect\"\nDETAIL:  User does not have CONNECT privilege.\n",
          "FATAL:  permission denied for database \"iostreams_fix_qp_noconnect\"\nDETAIL:  User does not have CONNECT " \
          "privilege.\n"
        ]
      )
    end

    it "returns Unavailable for a server that cannot be reached, or has no connection free" do
      assert_connection_kind(
        IOStreams::Errors::Unavailable,
        [
          "connection to server at \"127.0.0.1\", port 1 failed: Connection refused\n\tIs the server running on that " \
          "host and accepting TCP/IP connections?\nconnection to server at \"::1\", port 1 failed: Connection refused\n" \
          "\tIs the server running on that host and accepting TCP/IP connections?\n",
          "connection to server at \"10.255.255.1\", port 55432 failed: timeout expired",
          # glibc, and musl.
          "connection to server at \"10.1.2.3\", port 5432 failed: Network is unreachable\n\tIs the server running on " \
          "that host and accepting TCP/IP connections?\n",
          "connection to server at \"172.21.0.250\", port 5432 failed: No route to host\n\tIs the server running on " \
          "that host and accepting TCP/IP connections?\n",
          "connection to server at \"2001:db8::1\", port 5432 failed: Network unreachable\n\tIs the server running on " \
          "that host and accepting TCP/IP connections?\n",
          "connection to server at \"172.21.0.250\", port 5432 failed: Host is unreachable\n\tIs the server running on " \
          "that host and accepting TCP/IP connections?\n",
          "could not connect to server: Host is unreachable\n\tIs the server running on host \"172.21.0.250\" and " \
          "accepting\n\tTCP/IP connections on port 5432?\n",
          # A server that is not running locally.
          "connection to server on socket \"/tmp/iostreams_fix_qp_nosocket/.s.PGSQL.55432\" failed: No such file or " \
          "directory\n\tIs the server running locally and accepting connections on that socket?\n",
          "could not connect to server: No such file or directory\n\tIs the server running locally and accepting\n" \
          "\tconnections on Unix domain socket \"/tmp/nosocket/.s.PGSQL.5432\"?\n",
          # A temporary failure of name resolution, with glibc, and musl.
          "could not translate host name \"db.example.org\" to address: Temporary failure in name resolution\n",
          "could not translate host name \"db.example.org\" to address: Try again\n",
          "FATAL:  sorry, too many clients already",
          "FATAL:  the database system is starting up",
          # The last attempt timed out, after the first was refused.
          "connection to server at \"127.0.0.1\", port 55498 failed: FATAL:  RADIUS authentication failed for user " \
          "\"iostreams_fix_qp_radius\"\nconnection to server at \"127.0.0.1\", port 55498 failed: timeout expired"
        ]
      )
    end

    it "returns NONE for a host that does not resolve, or a database that does not exist, by the last attempt" do
      assert_connection_kind(
        IOStreams::Query::Failure::NONE,
        [
          # macOS, glibc, and musl.
          "could not translate host name \"postgres-db.invalid\" to address: nodename nor servname provided, or not " \
          "known\n",
          "could not translate host name \"iostreams-no-such-host.invalid\" to address: Name or service not known\n",
          "could not translate host name \"iostreams-no-such-host.invalid\" to address: Name does not resolve\n",
          "connection to server at \"127.0.0.1\", port 55432 failed: FATAL:  database \"iostreams_fix_qp_missing\" does " \
          "not exist\n",
          "FATAL:  database \"iostreams_fix_qp_missing\" does not exist\n",
          # Each address of a host, the first of which refused the connection.
          "connection to server at \"pgdual\" (172.21.0.2), port 5432 failed: Connection refused\n\tIs the server " \
          "running on that host and accepting TCP/IP connections?\nconnection to server at \"pgdual\" (172.21.0.3), " \
          "port 5432 failed: FATAL:  database \"iostreams_fix_qp_missing\" does not exist\n"
        ]
      )
    end

    # Which Active Record names a connection that could not be established, unless the message names the host as it was
    # configured, such as "::1" for localhost, when it is a `DatabaseConnectionError` that is not tagged.
    it "returns NONE for a failure of TLS that a retry does not change, but Unavailable for a connection that was reset" do
      assert_connection_kind(
        IOStreams::Query::Failure::NONE,
        [
          "connection to server at \"::1\", port 5432 failed: server does not support SSL, but SSL was required\n",
          "connection to server at \"db\" (10.0.0.1), port 5432 failed: SSL error: certificate verify failed\n",
          "connection to server at \"db\" (10.0.0.1), port 5432 failed: server certificate for \"other\" does not " \
          "match host name \"db\"\n",
          "connection to server at \"db\" (10.0.0.1), port 5432 failed: root certificate file " \
          "\"/root/.postgresql/root.crt\" does not exist\n"
        ]
      )
      assert_connection_kind(
        IOStreams::Errors::Unavailable,
        ["connection to server at \"db\" (10.0.0.1), port 5432 failed: SSL SYSCALL error: Connection reset by peer\n"]
      )
    end

    it "returns nil for any other failure of a connection, such as one that the pg gem closed, which Active Record names" do
      assert_connection_kind(nil, ["connection is closed"])
    end
  end

  describe "IOStreams::Query::PostgresqlJdbc.failure_kind" do
    # Once a connection of the tests has loaded PgJDBC.
    before { skip "Only JRuby reads PostgreSQL with AR-JDBC" unless QueryDatabase.jdbc? && QueryDatabase.find("PostgreSQL") }

    # Returns [Module|nil] the kind of failure of an exception of PgJDBC that the server raised with the supplied
    # SQLSTATE, wrapped in an `ActiveRecord::JDBCError`, as AR-JDBC raises it.
    def server_kind(state)
      message   = Java::OrgPostgresqlUtil::ServerErrorMessage.new("SFATAL\u0000C#{state}\u0000Mfailed\u0000")
      exception = Java::OrgPostgresqlUtil::PSQLException.new(message)
      IOStreams::Query::PostgresqlJdbc.failure_kind(ActiveRecord::JDBCError.new(nil, exception))
    end

    # Returns [Module|nil] the kind of failure of an exception of PgJDBC of its own for a connection, with the supplied
    # cause.
    def connection_kind(state, cause = nil)
      exception = Java::OrgPostgresqlUtil::PSQLException.new("The connection attempt failed.", state, cause)
      IOStreams::Query::PostgresqlJdbc.failure_kind(exception)
    end

    it "returns the kind of failure of the SQLSTATE of the server" do
      assert_equal IOStreams::Errors::PermissionDenied, server_kind("42501")
      assert_equal IOStreams::Errors::PermissionDenied, server_kind("28P01")
      assert_equal IOStreams::Errors::Unavailable, server_kind("57P01")
      assert_equal IOStreams::Errors::Unavailable, server_kind("53300")
      assert_equal IOStreams::Errors::Unavailable, server_kind("25P03")
      assert_equal IOStreams::Query::Failure::NONE, server_kind("3D000")
      assert_nil server_kind("42P01")
    end

    it "returns nil for a connection that its configuration does not let PgJDBC make, which a retry does not change" do
      assert_nil connection_kind(Java::OrgPostgresqlUtil::PSQLState::CONNECTION_REJECTED)
    end

    it "returns NONE for a failure of TLS that a retry does not change, but Unavailable for a connection that was reset" do
      states    = Java::OrgPostgresqlUtil::PSQLState
      untrusted = Java::JavaxNetSsl::SSLHandshakeException.new("PKIX path building failed")
      untrusted.initCause(Java::JavaSecurityCert::CertificateException.new("unable to find valid certification path"))
      reset = Java::JavaxNetSsl::SSLException.new("Connection reset")
      reset.initCause(Java::JavaNet::SocketException.new("Connection reset"))

      assert_equal IOStreams::Query::Failure::NONE, connection_kind(states::CONNECTION_FAILURE, untrusted)
      assert_equal IOStreams::Errors::Unavailable, connection_kind(states::CONNECTION_FAILURE, reset)
    end

    # When AR-JDBC retries a statement on a connection that it cannot make again, it wraps the exception that caused the
    # failure to connect, which it gives the `ActiveRecord::JDBCError` as the cause that Ruby records, while `#cause`
    # returns the exception that was being rescued when AR-JDBC created it, if any.
    it "returns Unavailable for a connection that AR-JDBC could not make again, whose exception is not a SQLException" do
      require "jruby"
      refused = begin
        Java::OrgPostgresql::Driver.new.connect("jdbc:postgresql://127.0.0.1:1/iostreams_test", Java::JavaUtil::Properties.new)

        flunk "Connected to port 1"
      rescue Java::JavaSql::SQLException => e
        e.cause
      end
      error = begin
        raise(ArgumentError, "an exception that the application rescued")
      rescue ArgumentError
        Java::ArjdbcJdbc::RubyJdbcConnection.wrapException(JRuby.runtime.current_context,
                                                           JRuby.reference(ActiveRecord::JDBCError), refused,
                                                           refused.toString).getException
      end

      assert_kind_of Java::JavaNet::ConnectException, refused
      assert_nil error.jdbc_exception
      assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::PostgresqlJdbc.failure_kind(error)
    end

    it "returns nil for an exception that PgJDBC did not raise" do
      assert_nil IOStreams::Query::PostgresqlJdbc.failure_kind(RuntimeError.new("other"))
      assert_nil IOStreams::Query::PostgresqlJdbc.failure_kind(Java::JavaSql::SQLException.new("other", "08006"))
    end
  end
end
