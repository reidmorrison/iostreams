# frozen_string_literal: true

require_relative "query_helper"

# Reads a query on MySQL with the mysql2 gem, see `IOStreams::Query::Mysql2Stream`, when MYSQL_URL is set, or on JRuby
# with the MySQL adapter of AR-JDBC, see `IOStreams::Query::MysqlJdbc`, which reads it as `Mysql2Stream` does, apart from
# what its driver, Connector/J, raises.
class Mysql2StreamTest < Minitest::Test
  if (database = QueryDatabase.find("MySQL"))
    describe(QueryDatabase.jdbc? ? IOStreams::Query::MysqlJdbc : IOStreams::Query::Mysql2Stream) do
      include QueryTestMethods

      let(:db) { database }
      let(:jdbc) { QueryDatabase.jdbc? }
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

      # Returns [Class] the exception that the driver raises for an error that ends a streamed result.
      def driver_error
        jdbc ? ActiveRecord::JDBCError : Mysql2::Error
      end

      # Returns [Class] the exception that Active Record raises for a connection that could not be made, which AR-JDBC
      # raises as it raises every error of its driver, `ActiveRecord::JDBCError`, apart from one whose message names the
      # database, `ActiveRecord::NoDatabaseError`.
      def connection_error
        jdbc ? ActiveRecord::StatementInvalid : ActiveRecord::ConnectionNotEstablished
      end

      # Returns [Integer] the number of the error of MySQL that caused the supplied exception of Active Record, which on
      # JRuby is, or was caused by, an `ActiveRecord::JDBCError`, or the `java.sql.SQLException` of Connector/J.
      def error_number(error)
        return error.cause.error_number unless jdbc

        error = error.cause until error.respond_to?(:error_code)
        error.error_code
      end

      # Asserts the number of the error of MySQL that the driver ended a streamed result with: none from mysql2, which
      # raises it without its number, see `IOStreams::Query::MysqlFailure`, and the supplied one from Connector/J.
      def assert_streamed_number(number, error)
        jdbc ? assert_equal(number, error.error_code) : assert_nil(error.error_number)
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

      it "reads a connection of mysql2, or on JRuby one of the MySQL adapter of AR-JDBC, whose name is the same" do
        db.record.with_connection do |connection|
          assert_equal !jdbc, IOStreams::Query::Mysql2Stream.reads?(connection)
          assert_equal jdbc, IOStreams::Query::MysqlJdbc.reads?(connection)
        end
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

      # The server sends 25 MB, far more than the buffers of the sockets in between hold, so that it waits for the client
      # to take its rows while the block sleeps, for longer than the net_write_timeout of the session.
      it "keeps the connection while the block is slower than the net_write_timeout of the session" do
        numbers = "WITH RECURSIVE numbers (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 50) " \
                  "SELECT a.n FROM numbers AS a, numbers AS b"
        count   = 0
        IOStreams.stream(hasty.from("(#{numbers}) AS orders").select("n, REPEAT('x', 10000) AS wide")).each(:hash) do |_row|
          sleep(2.5) if count == 1
          count += 1
        end

        assert_equal 2_500, count
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

      it "tags a query that KILL QUERY ends while its rows are read as Unavailable" do
        rows  = 0
        error = assert_raises(driver_error) do
          IOStreams.stream(slow_orders("iostreams kill query")).each(:hash) do |_order|
            kill("QUERY", "iostreams kill query") if rows.zero?
            rows += 1
          end
        end

        assert_kind_of IOStreams::Errors::Unavailable, error
        assert_streamed_number 1317, error
        # Which AR-JDBC names with the class of the exception of Connector/J.
        assert_match(/\A#{db.order.name} query: (?:com\.mysql\.\S+: )?Query execution was interrupted\z/, error.message)
        assert_operator rows, :<, 103
      end

      it "tags a query that max_execution_time ends while its rows are read as Unavailable" do
        rows   = 0
        stream = IOStreams.stream(slow_orders("iostreams timeout").optimizer_hints("MAX_EXECUTION_TIME(300)"))
        error  = assert_raises(driver_error) { stream.each(:hash) { |_order| rows += 1 } }

        assert_kind_of IOStreams::Errors::Unavailable, error
        assert_streamed_number 3024, error
        assert_equal "#{db.order.name} query: Query execution was interrupted, maximum statement execution time exceeded",
                     error.message
        assert_operator rows, :<, 103
      end

      it "tags a connection that the server ends while the rows are read as Unavailable" do
        rows  = 0
        error = assert_raises(driver_error) do
          IOStreams.stream(slow_orders("iostreams kill connection")).each(:hash) do |_order|
            kill("CONNECTION", "iostreams kill connection") if rows.zero?
            rows += 1
          end
        end

        assert_kind_of IOStreams::Errors::Unavailable, error
        assert_streamed_number 0, error
        # As the client library of Oracle, or that of MariaDB, says it, or Connector/J, for the socket that was closed.
        lost = jdbc ? "Error retrieving record: .*EOFException" : "Lost connection to (?:MySQL )?server during query\\z"

        assert_match(/\A#{db.order.name} query: #{lost}/m, error.message)
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
        error  = assert_raises(connection_error) { each(IOStreams.stream(orders.all)) }

        assert_kind_of IOStreams::Errors::Unavailable, error
        if jdbc
          # The communications link failure of Connector/J, which has no number.
          assert_equal "08S01", error.sql_state
        else
          # CR_CONNECTION_ERROR or CR_CONN_HOST_ERROR, as the client library reports a refused connection.
          assert_includes [2002, 2003], error.cause.error_number
        end
      end

      it "tags a password that the server rejects as PermissionDenied" do
        orders = db.orders_at("Wrong", password: "wrong")
        error  = assert_raises(connection_error) { each(IOStreams.stream(orders.all)) }

        assert_kind_of IOStreams::Errors::PermissionDenied, error
      end

      it "tags a user that may not use the database as PermissionDenied" do
        stranger = create_user("stranger")
        orders   = db.orders_at("Stranger", user: stranger, password: "stranger")
        error    = assert_raises(connection_error) { each(IOStreams.stream(orders.all)) }

        assert_kind_of IOStreams::Errors::PermissionDenied, error
        assert_equal 1044, error_number(error)
      end

      it "tags an account that MySQL does not let connect as PermissionDenied, such as one that is locked" do
        refused_accounts.each do |role, options, password, number|
          user   = create_user(role, options)
          orders = db.orders_at("Refused#{role.capitalize}", user: user, password: password)
          error  = assert_raises(connection_error) { each(IOStreams.stream(orders.all)) }

          assert_kind_of IOStreams::Errors::PermissionDenied, error, role
          assert_equal number, error_number(error), role
        end
      end

      it "tags a function that the user may not run as PermissionDenied" do
        orders = orders_without_execute("mysql2")
        error  = assert_raises(ActiveRecord::StatementInvalid) do
          each(IOStreams.stream(orders.select("iostreams_double(amount) AS doubled")))
        end

        assert_kind_of IOStreams::Errors::PermissionDenied, error
        assert_equal 1370, error_number(error)
      end

      it "does not tag a host that does not resolve" do
        orders = db.orders_at("Unknown", host: "iostreams-no-such-host.invalid")
        error  = assert_raises(connection_error) { each(IOStreams.stream(orders.all)) }

        refute_kind_of IOStreams::Errors::StorageError, error
      end

      describe "an unsigned bigint" do
        let(:model) do
          unless QueryDatabase::MySQL.const_defined?(:Serial)
            QueryDatabase::MySQL.const_set(:Serial, Class.new(db.record) { self.table_name = "serials" })
          end
          QueryDatabase::MySQL::Serial
        end

        before do
          execute("DROP TABLE IF EXISTS serials")
          execute("CREATE TABLE serials (id INT NOT NULL PRIMARY KEY, serial BIGINT UNSIGNED)")
          execute("INSERT INTO serials VALUES (1, 18446744073709551615), (2, 1)")
          model.reset_column_information
        end

        after { execute("DROP TABLE IF EXISTS serials") }

        it "is a number without decimals, since a 64-bit integer cannot hold all of its values" do
          stream = IOStreams.stream(model.order(:id).select(:serial))

          assert_equal [{name: "serial", type: "number", decimals: 0}], stream.schema[:fields]
          serials = each(stream).map { |row| row["serial"] }

          assert_equal [BigDecimal("18446744073709551615"), BigDecimal(1)], serials
          assert_equal model.order(:id).pluck(:serial), serials
          csv = StringIO.new
          IOStreams.stream(csv).format(:csv).copy_from(model.order(:id).select(:serial), mode: :hash)

          assert_equal "serial\n18446744073709551615\n1\n", csv.string
        end
      end

      describe "a TIME" do
        let(:model) do
          unless QueryDatabase::MySQL.const_defined?(:Clock)
            QueryDatabase::MySQL.const_set(:Clock, Class.new(db.record) { self.table_name = "clocks" })
          end
          QueryDatabase::MySQL::Clock
        end

        before do
          execute("DROP TABLE IF EXISTS clocks")
          execute(<<~SQL)
            CREATE TABLE clocks (
              id INT NOT NULL PRIMARY KEY, starts_at TIME(6), ends_at TIME, amount DECIMAL(10, 2), items INT,
              gift TINYINT(1), due_on DATE, seen_at DATETIME(6), doc JSON, name VARCHAR(20), ratio DOUBLE,
              serial BIGINT UNSIGNED, born YEAR
            )
          SQL
          execute(<<~SQL)
            INSERT INTO clocks VALUES
              (1, '14:30:15.250000', '23:59:59', 12.5, 3, 1, '2026-10-13', '2026-10-13 09:30:00.123456', '{"a": [1, 2]}',
               'Jack', 0.1, 18446744073709551615, 2026),
              (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
          SQL
          model.reset_column_information
        end

        after { execute("DROP TABLE IF EXISTS clocks") }

        it "is a time, of the clock of the app" do
          stream = IOStreams.stream(model.order(:id).select(:starts_at, :ends_at))

          assert_equal [{name: "starts_at", type: "time"}, {name: "ends_at", type: "time"}], stream.schema[:fields]
          csv = StringIO.new
          IOStreams.stream(csv).format(:csv).copy_from(stream, mode: :hash)

          assert_equal "starts_at,ends_at\n09:30:15.250,18:59:59\n,\n", csv.string
        end

        it "reads the text of the values of a query with a time, and casts each as pluck casts it" do
          # Apart from the unsigned bigint, a number without decimals, whose BigDecimal equals the Integer of pluck.
          names   = model.column_names - ["serial"]
          rows    = each(IOStreams.stream(model.order(:id).select(*names)), :array).drop(1)
          plucked = model.order(:id).pluck(*names)

          assert_equal plucked, rows
          assert_equal(plucked.map { |row| row.map(&:class) }, rows.map { |row| row.map(&:class) })
          assert_instance_of ActiveSupport::TimeWithZone, rows.first[names.index("seen_at")]
          assert_equal({"a" => [1, 2]}, rows.first[names.index("doc")])
          serials = each(IOStreams.stream(model.order(:id).select(:starts_at, :serial))).map { |row| row["serial"] }

          assert_equal [BigDecimal("18446744073709551615"), nil], serials
        end

        it "keeps the values that mysql2 casts of a query with a time and a column that it computes, as pluck does" do
          computed = [Arel.sql("items * 2 AS doubled"), Arel.sql("amount + 1 AS more"), Arel.sql("COUNT(*) OVER () AS total")]
          relation = model.order(:id).select(:id, :starts_at, *computed)
          rows     = each(IOStreams.stream(relation), :array).drop(1)
          plucked  = model.order(:id).pluck(:id, :starts_at, *computed)

          assert_equal plucked, rows
          assert_equal(plucked.map { |row| row.map(&:class) }, rows.map { |row| row.map(&:class) })
          assert_equal [1, 6, BigDecimal("13.5"), 2], rows.first.values_at(0, 2, 3, 4)
        end

        it "raises for a TIME outside a day, which mysql2 reads as nil, or the next day, or raises for" do
          skip "Connector/J raises for a TIME outside a day itself, see below" if jdbc
          ["25:30:00", "-01:00:00", "838:59:59", "24:00:00", "-00:00:01"].each do |time|
            execute("UPDATE clocks SET starts_at = '#{time}' WHERE id = 2")

            error = assert_raises(IOStreams::Errors::InvalidValue, time) { each(IOStreams.stream(model.order(:id))) }
            assert_match(/\AColumn "starts_at": "#{time}\.000000" is not a time of day, from 00:00:00 to 23:59:59/,
                         error.message)
          end
        end

        # As `pluck` does on JRuby, apart from a negative TIME of less than an hour, which Connector/J reads without its
        # sign, as a time of day, which IOStreams cannot tell apart from one.
        it "raises on JRuby for a TIME outside a day, as Connector/J does, apart from one of less than an hour before 0" do
          skip "mysql2 reads a TIME outside a day, see above" unless jdbc
          ["25:30:00", "-01:00:00", "838:59:59", "24:00:00"].each do |time|
            execute("UPDATE clocks SET starts_at = '#{time}' WHERE id = 2")

            error = assert_raises(ActiveRecord::JDBCError, time) { each(IOStreams.stream(model.order(:id))) }
            assert_match(/is an invalid TIME value/, error.message, time)
            assert_raises(ActiveRecord::StatementInvalid, time) { each(IOStreams.stream(model.in_batches(of: 1))) }
          end
          execute("UPDATE clocks SET starts_at = '-00:00:01' WHERE id = 2")
          clocks = each(IOStreams.stream(model.order(:id).select(:starts_at))).map { |row| row["starts_at"].strftime("%T") }

          # 00:00:01 UTC, as the clock of the app.
          assert_equal(model.order(:id).pluck(:starts_at).map { |time| time.strftime("%T") }, clocks)
          assert_equal "19:00:01", clocks.last
        end

        it "raises for a TIME of 24:00:00 in batches, which mysql2 reads as a time of the next day" do
          skip "Connector/J raises for a TIME outside a day itself, see above" if jdbc
          execute("UPDATE clocks SET starts_at = '24:00:00' WHERE id = 2")

          error = assert_raises(IOStreams::Errors::InvalidValue) { each(IOStreams.stream(model.in_batches(of: 1))) }
          assert_match(/\AColumn "starts_at": 2000-01-02 00:00:00 UTC is not a time of day/, error.message)
        end
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
