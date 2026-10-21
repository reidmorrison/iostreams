# frozen_string_literal: true

require_relative "query_helper"

# Reads a query on MySQL with the mysql2 gem, see `IOStreams::Query::Mysql2Stream`, when MYSQL_URL is set.
class Mysql2StreamTest < Minitest::Test
  if (database = QueryDatabase.find("MySQL"))
    describe IOStreams::Query::Mysql2Stream do
      include QueryTestMethods

      let(:db) { database }
      let(:orders) { db.order.order(:id) }
      # The orders on another pool, which watches the connection that reads a query, since that cannot run a query
      # while it streams a result.
      let(:monitor) { db.orders_at("Monitor") }
      # The orders on connections that the server ends when the client takes no row within a second.
      let(:hasty) { db.orders_at("Hasty", variables: {net_write_timeout: 1}) }
      # The users of MySQL that the test created, see #create_user.
      let(:users) { [] }

      before { db.load }

      after do
        users.each { |user| execute("DROP USER IF EXISTS '#{user}'@'%'") }
      end

      def execute(sql)
        db.record.with_connection { |connection| connection.execute(sql) }
      end

      # Returns [String] the name of a user of MySQL of this process, whose password is its role, created with the
      # supplied options of CREATE USER, such as `ACCOUNT LOCK`, and dropped once the test has run, see
      # QueryDatabase::MysqlDatabase.user.
      def create_user(role, options = nil)
        user = QueryDatabase::MysqlDatabase.user(role)
        execute("DROP USER IF EXISTS '#{user}'@'%'")
        execute("CREATE USER '#{user}'@'%' IDENTIFIED BY '#{role}' #{options}")
        users << user
        user
      end

      # Returns [Array] each account that MySQL does not let connect: its role, the options of CREATE USER that make it
      # so, the password that it connects with, and the number of the error that the server refuses it with.
      def refused_accounts
        [
          ["locked", "ACCOUNT LOCK", "locked", 3118],
          ["expired", "PASSWORD EXPIRE", "expired", 1862],
          # Blocked by its first failed login, which the server refuses with this error too.
          ["blocked", "FAILED_LOGIN_ATTEMPTS 1 PASSWORD_LOCK_TIME 1", "wrong", 3955]
        ]
      end

      # Returns [Class] a model of the orders table on a connection as a user who may read the orders, but not run the
      # function iostreams_double, which the database has, with the driver of the supplied scheme.
      def orders_without_execute(scheme)
        execute("DROP FUNCTION IF EXISTS iostreams_double")
        execute("CREATE FUNCTION iostreams_double(amount DECIMAL(10, 2)) RETURNS DECIMAL(10, 2) DETERMINISTIC " \
                "RETURN amount * 2")
        reader = create_user("reader")
        execute("GRANT SELECT ON orders TO '#{reader}'@'%'")
        db.orders_at("#{scheme.capitalize}Runner", scheme: scheme, user: reader, password: "reader")
      end

      # Returns [String] the net_write_timeout of the session of the supplied id, which another connection reads, since
      # the connection that reads a query cannot run a query while it streams a result.
      def net_write_timeout(connection_id)
        monitor.with_connection do |connection|
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
        default = monitor.with_connection { |connection| connection.select_value("SELECT @@GLOBAL.net_write_timeout") }

        assert_equal default.to_s, net_write_timeout(sessions.first)
      end

      it "keeps the connection while the block is slower than the net_write_timeout of the session" do
        execute("SET SESSION cte_max_recursion_depth = 20000")
        execute("INSERT INTO orders (name, amount, status) SELECT CONCAT(REPEAT('x', 200), n), n, 0 FROM " \
                "(WITH RECURSIVE numbers (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 20000) " \
                "SELECT n FROM numbers) AS numbers")
        count = 0
        IOStreams.stream(hasty.order(:id).select(:id, :name)).each(:hash) do |_order|
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
        reader = create_user("reader")
        # A table of the database, so that the user can connect to it, but not the orders.
        execute("GRANT SELECT ON customers TO '#{reader}'@'%'")
        orders = db.orders_at("Reader", user: reader, password: "reader")
        error  = assert_raises(ActiveRecord::StatementInvalid) { each(IOStreams.stream(orders.all)) }

        assert_kind_of IOStreams::Errors::PermissionDenied, error
        assert_match(/SELECT command denied to user '#{reader}'/, error.message)
      end

      it "tags a server that refuses the connection as Unavailable" do
        orders = db.orders_at("Refused", port: 1)
        error  = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(orders.all)) }

        assert_kind_of IOStreams::Errors::Unavailable, error
        # CR_CONNECTION_ERROR or CR_CONN_HOST_ERROR, as the client library reports a refused connection.
        assert_includes [2002, 2003], error.cause.error_number
      end

      it "tags a password that the server rejects as PermissionDenied" do
        orders = db.orders_at("Wrong", password: "wrong")
        error  = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(orders.all)) }

        assert_kind_of IOStreams::Errors::PermissionDenied, error
      end

      it "tags a user that may not use the database as PermissionDenied" do
        stranger = create_user("stranger")
        orders   = db.orders_at("Stranger", user: stranger, password: "stranger")
        error    = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(orders.all)) }

        assert_kind_of IOStreams::Errors::PermissionDenied, error
        assert_equal 1044, error.cause.error_number
      end

      it "tags an account that MySQL does not let connect as PermissionDenied, such as one that is locked" do
        refused_accounts.each do |role, options, password, number|
          user   = create_user(role, options)
          orders = db.orders_at("Refused#{role.capitalize}", user: user, password: password)
          error  = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(orders.all)) }

          assert_kind_of IOStreams::Errors::PermissionDenied, error, role
          assert_equal number, error.cause.error_number, role
        end
      end

      it "tags a function that the user may not run as PermissionDenied" do
        orders = orders_without_execute("mysql2")
        error  = assert_raises(ActiveRecord::StatementInvalid) do
          each(IOStreams.stream(orders.select("iostreams_double(amount) AS doubled")))
        end

        assert_kind_of IOStreams::Errors::PermissionDenied, error
        assert_equal 1370, error.cause.error_number
      end

      it "does not tag a host that does not resolve" do
        orders = db.orders_at("Unknown", host: "iostreams-no-such-host.invalid")
        error  = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(orders.all)) }

        refute_kind_of IOStreams::Errors::StorageError, error
      end

      describe "trilogy" do
        before do
          skip "The trilogy gem is not installed, see the mysql group of the Gemfile" unless QueryDatabase.driver?("trilogy")
        end

        let(:trilogy) { db.orders_at("Trilogy", scheme: "trilogy") }

        it "cannot stream a query, so it raises, suggesting batches, which it reads" do
          error = assert_raises(ArgumentError) { each(IOStreams.stream(trilogy.order(:id))) }

          assert_equal "IOStreams cannot stream a query on Trilogy, so read it in batches, such as with " \
                       "`IOStreams.stream(relation.in_batches(of: 10_000))`", error.message
          records = each(IOStreams.stream(trilogy.select(:id, :name).in_batches(of: 2)))

          assert_equal(orders.pluck(:name), records.map { |order| order["name"] })
        end

        it "tags a table that the user may not read as PermissionDenied" do
          reader = create_user("reader")
          execute("GRANT SELECT ON customers TO '#{reader}'@'%'")
          orders = db.orders_at("TrilogyReader", scheme: "trilogy", user: reader, password: "reader")
          error  = assert_raises(ActiveRecord::StatementInvalid) { each(IOStreams.stream(orders.in_batches(of: 2))) }

          assert_kind_of IOStreams::Errors::PermissionDenied, error
          assert_instance_of Trilogy::ProtocolError, error.cause
          assert_match(/SELECT command denied to user '#{reader}'/, error.message)
        end

        # The query that describes the columns connects before trilogy is refused as a source, while `in_batches` would
        # connect in Rails, for the primary key.
        it "tags a user that may not use the database as PermissionDenied, which Active Record says does not exist" do
          stranger = create_user("stranger")
          orders   = db.orders_at("TrilogyStranger", scheme: "trilogy", user: stranger, password: "stranger")
          error    = assert_raises(ActiveRecord::NoDatabaseError) { each(IOStreams.stream(orders.all)) }

          assert_kind_of IOStreams::Errors::PermissionDenied, error
          assert_equal 1044, error.cause.error_code
        end

        it "tags an account that MySQL does not let connect as PermissionDenied, such as one that is locked" do
          refused_accounts.each do |role, options, password, number|
            user   = create_user(role, options)
            orders = db.orders_at("TrilogyRefused#{role.capitalize}", scheme: "trilogy", user: user, password: password)
            error  = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(orders.all)) }

            assert_kind_of IOStreams::Errors::PermissionDenied, error, role
            assert_equal number, error.cause.error_code, role
          end
        end

        it "tags a function that the user may not run as PermissionDenied" do
          orders = orders_without_execute("trilogy")
          error  = assert_raises(ActiveRecord::StatementInvalid) do
            each(IOStreams.stream(orders.select("iostreams_double(amount) AS doubled")))
          end

          assert_kind_of IOStreams::Errors::PermissionDenied, error
          assert_equal 1370, error.cause.error_code
        end
      end
    end
  end

  describe ".failure_kind" do
    before do
      unless QueryDatabase.driver?("mysql2")
        skip "The mysql2 gem is not installed, see the optional mysql group of the Gemfile, and JRuby cannot load it"
      end
    end

    def kind(exception)
      IOStreams::Query::Mysql2Stream.failure_kind(exception)
    end

    # Returns [Mysql2::Error] the exception that mysql2 raises for an error of the client library, or that the server
    # sent, with its number, as its C extension makes it, which is of the class that mysql2 gives the error number.
    def numbered_error(number, message)
      Mysql2::Error.new_with_args(message, 80_400, number, "HY000")
    end

    it "returns what MySQL says of the error number, whatever the class that mysql2 gives it" do
      assert_equal IOStreams::Errors::PermissionDenied,
                   kind(numbered_error(1142, "SELECT command denied to user 'jack'@'%' for table 'orders'"))
      # mysql2 raises it as a connection error.
      denied = numbered_error(1044, "Access denied for user 'jack'@'%' to database 'shop'")

      assert_kind_of Mysql2::Error::ConnectionError, denied
      assert_equal IOStreams::Errors::PermissionDenied, kind(denied)
      assert_equal IOStreams::Errors::Unavailable, kind(numbered_error(2013, "Lost connection to MySQL server during query"))
      assert_nil kind(numbered_error(1146, "Table 'shop.order' doesn't exist"))
      assert_nil kind(RuntimeError.new("other"))
    end
  end
end
