# frozen_string_literal: true

require_relative "query_helper"

# Reads a query on MySQL with the mysql2 gem, see `IOStreams::Query::Mysql2Stream`, when MYSQL_URL is set.
class Mysql2StreamTest < Minitest::Test
  if (database = QueryDatabase.find("MySQL"))
    # Connects to the same database as the supplied url, with the supplied scheme, user and password, and the rest of
    # the supplied configuration, so that a test can watch the connection that reads a query, or read it as another
    # user, with other settings of the session, or with trilogy.
    def self.connect(name, scheme: nil, user: nil, password: nil, host: nil, port: nil, **config)
      url          = URI(ENV.fetch("MYSQL_URL"))
      url.scheme   = scheme if scheme
      url.user     = user if user
      url.password = password if password
      url.host     = host if host
      url.port     = port if port
      record = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      QueryDatabase::MySQL.const_set(:"#{name}Record", record)
      record.establish_connection(url: url.to_s, pool: 2, **config)
      order = Class.new(record) { self.table_name = "orders" }
      QueryDatabase::MySQL.const_set(:"#{name}Order", order)
      order
    end

    MONITOR = connect("Monitor")
    TRILOGY = connect("Trilogy", scheme: "trilogy")
    READER  = connect("Reader", user: "iostreams_reader", password: "reader")
    REFUSED = connect("Refused", port: 1)
    WRONG   = connect("Wrong", password: "wrong")
    UNKNOWN = connect("Unknown", host: "iostreams-no-such-host.invalid")
    # The orders on connections that the server ends when the client takes no row within a second.
    HASTY = connect("Hasty", variables: {net_write_timeout: 1})

    describe IOStreams::Query::Mysql2Stream do
      include QueryTestMethods

      let(:db) { database }
      let(:orders) { db.order.order(:id) }

      before { db.load }

      def execute(sql)
        db.record.with_connection { |connection| connection.execute(sql) }
      end

      # Returns [String] the net_write_timeout of the session of the connection of the pool, which another connection
      # reads, since the connection cannot run a query while it streams a result.
      def net_write_timeout(connection_id)
        MONITOR.with_connection do |connection|
          connection.select_value(<<~SQL)
            SELECT VARIABLE_VALUE FROM performance_schema.variables_by_thread AS variables
            JOIN performance_schema.threads AS threads ON threads.THREAD_ID = variables.THREAD_ID
            WHERE threads.PROCESSLIST_ID = #{Integer(connection_id)} AND VARIABLE_NAME = 'net_write_timeout'
          SQL
        end
      end

      # Returns [ActiveRecord::Relation] the orders with the id of the session of the connection that reads them, see
      # `IOStreams::Query#open`, in the column "session".
      def with_session(orders)
        orders.select(:id, Arel.sql("CONNECTION_ID() AS session"))
      end

      it "reads a connection of mysql2" do
        assert(db.record.with_connection { |connection| IOStreams::Query::Mysql2Stream.reads?(connection) })
      end

      it "raises net_write_timeout while the rows are read, and sets it back" do
        sessions = []
        timeout  = []
        IOStreams.stream(with_session(orders)).each(:hash) do |order|
          sessions << order["session"]
          timeout << net_write_timeout(order["session"])
        end

        assert_equal %w[3600 3600 3600], timeout
        assert_equal 1, sessions.uniq.size
        default = MONITOR.with_connection { |connection| connection.select_value("SELECT @@GLOBAL.net_write_timeout") }

        assert_equal default.to_s, net_write_timeout(sessions.first)
      end

      it "keeps the connection while the block is slower than the net_write_timeout of the session" do
        execute("SET SESSION cte_max_recursion_depth = 20000")
        execute("INSERT INTO orders (name, amount, status) SELECT CONCAT(REPEAT('x', 200), n), n, 0 FROM " \
                "(WITH RECURSIVE numbers (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 20000) " \
                "SELECT n FROM numbers) AS numbers")
        count = 0
        IOStreams.stream(HASTY.order(:id).select(:id, :name)).each(:hash) do |_order|
          sleep(2.5) if count == 1
          count += 1
        end

        assert_equal 20_003, count
      ensure
        execute("SET SESSION cte_max_recursion_depth = DEFAULT")
      end

      it "reads the query on a connection of its own, so that the block queries the database on that of the caller" do
        sessions = []
        counts   = []
        callers  = db.record.with_connection do |connection|
          IOStreams.stream(with_session(orders)).each(:hash) do |order|
            sessions << order["session"]
            counts << db.customer.count
          end
          connection.select_value("SELECT CONNECTION_ID()")
        end

        assert_equal [2, 2, 2], counts
        refute_includes sessions, callers
      end

      it "does not explain any other exception of the block" do
        assert_raises(ActiveRecord::RecordNotFound) do
          IOStreams.stream(orders).each(:hash) { |_order| raise ActiveRecord::RecordNotFound } # rubocop:disable Lint/UnreachableLoop -- raises on its first row
        end

        assert_equal 3, db.order.count
      end

      it "types the computed columns as any, since mysql2 reports no types, while their values are typed" do
        stream = IOStreams.stream(db.order.select("SUM(amount) AS total, COUNT(*) AS orders"))

        assert_equal [{name: "total", type: "any"}, {name: "orders", type: "any"}], stream.schema[:fields]
        assert_equal [{"total" => BigDecimal("115.75"), "orders" => 3}], each(stream)
      end

      it "tags a table that the user may not read as PermissionDenied" do
        execute("CREATE USER IF NOT EXISTS 'iostreams_reader'@'%' IDENTIFIED BY 'reader'")
        # A table of the database, so that the user can connect to it, but not the orders.
        execute("GRANT SELECT ON customers TO 'iostreams_reader'@'%'")
        error = assert_raises(ActiveRecord::StatementInvalid) { each(IOStreams.stream(READER.all)) }

        assert_kind_of IOStreams::Errors::PermissionDenied, error
        assert_match(/SELECT command denied to user 'iostreams_reader'/, error.message)
      end

      it "tags a server that refuses the connection as Unavailable" do
        error = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(REFUSED.all)) }

        assert_kind_of IOStreams::Errors::Unavailable, error
        # CR_CONNECTION_ERROR or CR_CONN_HOST_ERROR, as the client library reports a refused connection.
        assert_includes [2002, 2003], error.cause.error_number
      end

      it "tags a password that the server rejects as PermissionDenied" do
        error = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(WRONG.all)) }

        assert_kind_of IOStreams::Errors::PermissionDenied, error
      end

      it "does not tag a host that does not resolve" do
        error = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(UNKNOWN.all)) }

        refute_kind_of IOStreams::Errors::StorageError, error
      end

      describe "trilogy" do
        it "cannot stream a query, so it raises, suggesting batches, which it reads" do
          error = assert_raises(ArgumentError) { each(IOStreams.stream(TRILOGY.order(:id))) }

          assert_equal "IOStreams cannot stream a query on Trilogy, so read it in batches, such as with " \
                       "`IOStreams.stream(relation.in_batches(of: 10_000))`", error.message
          records = each(IOStreams.stream(TRILOGY.select(:id, :name).in_batches(of: 2)))

          assert_equal(orders.pluck(:name), records.map { |order| order["name"] })
        end
      end
    end
  end

  describe ".failure_kind" do
    it "returns the kind of failure of an error number of MySQL" do
      skip "The mysql2 gem is a C extension, which JRuby cannot load" unless QueryDatabase.driver?("mysql2")

      error = ->(number) { Mysql2::Error.new("failed", nil, number) }

      assert_equal IOStreams::Errors::PermissionDenied, IOStreams::Query::Mysql2Stream.failure_kind(error.call(1142))
      assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::Mysql2Stream.failure_kind(error.call(2013))
      assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::Mysql2Stream.failure_kind(error.call(3024))
      assert_equal IOStreams::Errors::Unavailable, IOStreams::Query::Mysql2Stream.failure_kind(error.call(2003))
      assert_equal IOStreams::Errors::PermissionDenied, IOStreams::Query::Mysql2Stream.failure_kind(error.call(1045))
      assert_nil IOStreams::Query::Mysql2Stream.failure_kind(error.call(2005))
      assert_nil IOStreams::Query::Mysql2Stream.failure_kind(error.call(1146))
      assert_nil IOStreams::Query::Mysql2Stream.failure_kind(RuntimeError.new("other"))
    end
  end
end
