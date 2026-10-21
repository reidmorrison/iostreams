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

      # Returns [ActiveRecord::Relation] a query of 103 orders that is still running when the block reads its first row,
      # since the server takes 0.05 seconds for each row, which is wider than its buffer, so that it is sent at once. The
      # annotation names the query, so that another connection finds it, see #kill.
      def slow_orders(annotation)
        execute("INSERT INTO orders (name, amount, status) SELECT CONCAT('x', n), n, 0 FROM " \
                "(WITH RECURSIVE numbers (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 100) " \
                "SELECT n FROM numbers) AS numbers")
        orders.select("orders.id, REPEAT('x', 20000) AS wide, SLEEP(0.05) AS slept").annotate(annotation)
      end

      # Ends the query of the supplied annotation, or its connection, with KILL QUERY or KILL CONNECTION from another
      # connection, see #slow_orders.
      def kill(what, annotation)
        monitor.with_connection do |connection|
          id = connection.select_value("SELECT ID FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() AND " \
                                       "INFO LIKE '%#{annotation}%'")
          connection.execute("KILL #{what} #{Integer(id)}")
        end
      end

      # Returns [String] the value of the supplied variable of the session of the supplied id, which another connection
      # reads, since the connection that reads a query cannot run a query while it streams a result.
      def variable(connection_id, name)
        monitor.with_connection do |connection|
          connection.select_value(<<~SQL)
            SELECT VARIABLE_VALUE FROM performance_schema.variables_by_thread AS variables
            JOIN performance_schema.threads AS threads ON threads.THREAD_ID = variables.THREAD_ID
            WHERE threads.PROCESSLIST_ID = #{Integer(connection_id)} AND VARIABLE_NAME = #{connection.quote(name)}
          SQL
        end
      end

      # Returns [String] the net_write_timeout of the session of the supplied id, see #variable.
      def net_write_timeout(connection_id)
        variable(connection_id, "net_write_timeout")
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

      it "keeps a net_write_timeout of the session that is higher" do
        patient  = db.orders_at("Patient", variables: {net_write_timeout: 7200})
        sessions = []
        timeout  = []
        IOStreams.stream(with_session(patient.order(:id))).each(:hash) do |order|
          sessions << order["session"]
          timeout << net_write_timeout(order["session"])
        end

        assert_equal %w[7200 7200 7200], timeout
        assert_equal "7200", net_write_timeout(sessions.first)
      end

      it "ends the connection whose net_write_timeout it cannot set back, rather than fail a read of every row" do
        sessions = []
        IOStreams.stream(with_session(orders)).each(:hash) do |order|
          sessions << order["session"]
          # Every row, and the end of the result, have been sent, so that the connection is lost only to set it back.
          next unless sessions.size == 3

          monitor.with_connection { |connection| connection.execute("KILL CONNECTION #{Integer(order['session'])}") }
        end

        assert_equal 3, sessions.size
        refute session?(sessions.first)
        assert_equal 3, each(IOStreams.stream(orders)).size
      end

      # Since it counts the time that the client takes as well, and MySQL ends the query when it is over, which a retry
      # would meet again.
      it "lifts a max_execution_time of the session while the rows are read, and sets it back" do
        limited  = db.orders_at("Limited", variables: {max_execution_time: 300})
        sessions = []
        relation = limited.order(:id).select(:id, Arel.sql("CONNECTION_ID() AS session"), Arel.sql("SLEEP(0.2) AS slept"))
        IOStreams.stream(relation).each(:hash) { |order| sessions << order["session"] }

        assert_equal 3, sessions.size
        assert_equal "300", variable(sessions.first, "max_execution_time")
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

      # Since mysql2 would end the connection, and its transaction, for a query of the block, which Active Record would then
      # run on a new connection, so that the read would end without the rest of its rows.
      it "reads the query whole on a connection that the block shares, such as a pinned one, so that the block can query it" do
        db.pool.pin_connection!(false)
        begin
          db.order.create!(name: "d", amount: 4)
          names  = []
          counts = []
          IOStreams.stream(orders.select(:name)).each(:hash) do |order|
            names << order["name"]
            counts << db.customer.count
          end

          assert_equal %w[a b c d], names
          assert_equal [2, 2, 2, 2], counts
          # The transaction of the connection is still open, with the order that it created.
          assert_equal 4, db.order.count
        ensure
          db.pool.unpin_connection!
        end

        assert_equal 3, db.order.count
      end

      # With lock_threads, the threads of the application, such as the server of a system test, share the pinned
      # connection, as the read does.
      it "lets another thread query a connection that it shares while the block runs" do
        db.pool.pin_connection!(true)
        begin
          names  = []
          counts = []
          IOStreams.stream(orders.select(:name)).each(:hash) do |order|
            names << order["name"]
            counts << Thread.new { db.order.count }.value
          end

          assert_equal %w[a b c], names
          assert_equal [3, 3, 3], counts
        ensure
          db.pool.unpin_connection!
        end
      end

      # A connection that the application used raw is one that Active Record no longer verifies, nor reconnects, until
      # it is checked out again, which a caller that holds it does not do.
      it "does not use the raw connection of a connection that it shares, such as a pinned one" do
        db.pool.pin_connection!(false)
        begin
          pinned = db.pool.checkout

          pinned.stub(:raw_connection, -> { flunk("The read used the raw connection of the connection that it shares") }) do
            assert_equal 3, each(IOStreams.stream(orders)).size
          end
        ensure
          db.pool.unpin_connection!
        end
      end

      it "leaves the connection of the caller to Active Record, which reconnects it once its session has ended" do
        db.record.with_connection do |connection|
          assert_equal 3, each(IOStreams.stream(orders)).size
          id = connection.select_value("SELECT CONNECTION_ID()")
          monitor.with_connection { |watcher| watcher.execute("KILL CONNECTION #{Integer(id)}") }

          assert_equal %w[a b c], db.order.order(:id).pluck(:name)
        end
      end

      # Returns [true|false] whether the server still has the session of the supplied id, once it has had a second to end
      # it.
      def session?(connection_id)
        sql      = "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID = #{Integer(connection_id)}"
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        loop do
          open = monitor.with_connection { |connection| connection.select_value(sql) }.positive?
          return open unless open && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

          sleep(0.05)
        end
      end

      # Since freeing the result would read the rest of it, for which the server takes 0.05 seconds a row.
      it "ends the session of its own connection when the block leaves early, rather than read the rest of the result" do
        sessions = []
        relation = slow_orders("iostreams early exit").select(Arel.sql("CONNECTION_ID() AS session"))
        started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        IOStreams.stream(relation).each(:hash) do |order| # rubocop:disable Lint/UnreachableLoop -- leaves on its first row
          sessions << order["session"]
          break
        end

        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
        refute session?(sessions.first)
        # The pool reconnects the connection when it is next checked out.
        assert_equal 103, each(IOStreams.stream(orders)).size
      end

      it "does not explain any other exception of the block" do
        assert_raises(ActiveRecord::RecordNotFound) do
          IOStreams.stream(orders).each(:hash) { |_order| raise ActiveRecord::RecordNotFound } # rubocop:disable Lint/UnreachableLoop -- raises on its first row
        end

        assert_equal 3, db.order.count
      end

      # mysql2 raises an error that ends a streamed result without its number, see `IOStreams::Query::MysqlFailure`.
      it "tags a query that KILL QUERY ends while its rows are read as Unavailable" do
        rows  = 0
        error = assert_raises(Mysql2::Error) do
          IOStreams.stream(slow_orders("iostreams kill query")).each(:hash) do |_order|
            kill("QUERY", "iostreams kill query") if rows.zero?
            rows += 1
          end
        end

        assert_kind_of IOStreams::Errors::Unavailable, error
        assert_nil error.error_number
        assert_equal "#{db.order.name} query: Query execution was interrupted", error.message
        assert_operator rows, :<, 103
      end

      it "tags a query that max_execution_time ends while its rows are read as Unavailable" do
        rows   = 0
        stream = IOStreams.stream(slow_orders("iostreams timeout").optimizer_hints("MAX_EXECUTION_TIME(300)"))
        error  = assert_raises(Mysql2::Error) { stream.each(:hash) { |_order| rows += 1 } }

        assert_kind_of IOStreams::Errors::Unavailable, error
        assert_nil error.error_number
        assert_equal "#{db.order.name} query: Query execution was interrupted, maximum statement execution time exceeded",
                     error.message
        assert_operator rows, :<, 103
      end

      it "tags a connection that the server ends while the rows are read as Unavailable" do
        rows  = 0
        error = assert_raises(Mysql2::Error) do
          IOStreams.stream(slow_orders("iostreams kill connection")).each(:hash) do |_order|
            kill("CONNECTION", "iostreams kill connection") if rows.zero?
            rows += 1
          end
        end

        assert_kind_of IOStreams::Errors::Unavailable, error
        assert_nil error.error_number
        # As the client library of Oracle, or that of MariaDB, says it.
        assert_match(/\A#{db.order.name} query: Lost connection to (?:MySQL )?server during query\z/, error.message)
        assert_operator rows, :<, 103
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

        # trilogy raises its own exception for the socket that cannot resolve the host, which Active Record raises as
        # `ConnectionNotEstablished`, without naming the host, which is otherwise Unavailable.
        it "does not tag a host that does not resolve" do
          orders = db.orders_at("TrilogyUnknown", scheme: "trilogy", host: "iostreams-no-such-host.invalid")
          error  = assert_raises(ActiveRecord::ConnectionNotEstablished) { each(IOStreams.stream(orders.all)) }

          refute_kind_of IOStreams::Errors::StorageError, error
          assert_instance_of Trilogy::BaseConnectionError, error.cause
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

  describe ".reads?" do
    # Returns a connection of the supplied adapter name, which raises when it is asked for its raw connection, since
    # that would mark the connection of the caller as used by the application.
    def connection(adapter_name)
      connection = Object.new
      connection.define_singleton_method(:adapter_name) { adapter_name }
      connection.define_singleton_method(:raw_connection) { raise "reads? asked for the raw connection" }
      connection
    end

    it "reads a connection of mysql2, by the name of its adapter" do
      skip "The mysql2 gem is not installed, see the optional mysql group of the Gemfile" unless QueryDatabase.driver?("mysql2")

      assert IOStreams::Query::Mysql2Stream.reads?(connection("Mysql2"))
      refute IOStreams::Query::Mysql2Stream.reads?(connection("Trilogy"))
    end

    it "does not read a connection named Mysql2 without the mysql2 gem, such as that of AR-JDBC on JRuby" do
      skip "The mysql2 gem is loaded" if QueryDatabase.driver?("mysql2")

      refute IOStreams::Query::Mysql2Stream.reads?(connection("Mysql2"))
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

    # As `Mysql2::Result#each` raises an error that ends a streamed result: with its message alone.
    it "returns what MySQL says of the message of an error without a number" do
      assert_equal IOStreams::Errors::Unavailable, kind(Mysql2::Error.new("Lost connection to MySQL server during query"))
      assert_equal IOStreams::Errors::Unavailable, kind(Mysql2::Error.new("Query execution was interrupted"))
      assert_nil kind(Mysql2::Error.new("Invalid date in field 'shipped_on': 2026-00-15"))
    end

    it "tags its own timeout, of the read_timeout of the connection, which has no number, as Unavailable" do
      timeout = Mysql2::Error::TimeoutError.new("Timeout waiting for a response from the last query. (waited 1 seconds)")

      assert_nil timeout.error_number
      assert_equal IOStreams::Errors::Unavailable, kind(timeout)
    end
  end
end
