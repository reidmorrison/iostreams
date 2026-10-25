# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "securerandom"
require "tmpdir"

# The query tests run in a process of their own, see the Rakefile, whose coverage is merged with that of the others.
SimpleCov.command_name("Query") if ENV["COVERAGE"]

begin
  require "active_record"
rescue LoadError
  nil
end

# The databases that the query tests read, each with the same tables, and models of its own, see QueryDatabase.each.
module QueryDatabase
  # The name of a database for tests: one for IOStreams, such as `iostreams_test`, or one for tests, such as `test` or
  # `myapp_test`, so that the tests never change a database of another application, such as one that POSTGRES_URL or
  # MYSQL_URL names for it.
  TEST_DATABASE = /\Aiostreams|(?:\A|_)test\z/

  # The seconds that a test waits to connect to a server, rather than the 120 of mysql2, so that a server that cannot be
  # reached fails the tests soon.
  CONNECT_TIMEOUT = 5

  # A database, the namespace of its models: `Record`, its abstract base class, `Customer` and `Order`, and the
  # configuration that they connect with.
  Database = Struct.new(:name, :namespace, :config) do
    def record = namespace::Record
    def customer = namespace::Customer
    def order = namespace::Order
    def pool = record.connection_pool

    # Returns the raw connection of the driver, of the connection that the caller borrows.
    def raw_connection
      record.with_connection(&:raw_connection)
    end

    # Replaces the rows of the tables with those of QueryDatabase.load.
    def load
      order.delete_all
      customer.delete_all
      QueryDatabase.load(self)
    end

    # Returns [Class] a model of the orders table on a pool of its own, of the configuration of the database, see
    # QueryDatabase.configs, at its url with the supplied parts changed, such as another port or user, and with the rest
    # of the supplied configuration, such as the `variables` of the session, so that a test can watch the connection
    # that reads a query, read it as another user, with other settings, or with another driver, by its scheme. Its
    # abstract base class is named by the supplied name in the namespace of the database, as Active Record needs,
    # replacing that of an earlier test.
    def orders_at(name, scheme: nil, host: nil, port: nil, user: nil, password: nil, **options)
      url      = URI(config.fetch(:url))
      userinfo = url.userinfo
      url.host = host if host
      url.port = port if port
      # Changing the host or the port of a url clears its user and password.
      url.userinfo = userinfo if userinfo
      url.user     = user if user
      url.password = password if password
      url.scheme   = scheme if scheme

      constant = :"#{name}Record"
      namespace.send(:remove_const, constant) if namespace.const_defined?(constant, false)
      record = namespace.const_set(constant, Class.new(ActiveRecord::Base) { self.abstract_class = true })
      record.establish_connection(config.merge(url: url.to_s, **options))
      Class.new(record) { self.table_name = "orders" }
    end
  end

  # Returns [true|false] whether the databases are read with the adapters of AR-JDBC, on JRuby, see .driver?.
  def self.jdbc?
    defined?(::ArJdbc) ? true : false
  end

  # Returns [Hash<String, Hash>] the configuration of each database that the tests can read: SQLite, unless its gem
  # cannot be loaded, as on JRuby, PostgreSQL, at the url of POSTGRES_URL, when it is set, in a schema of this
  # process, see PostgresqlSchema, and MySQL with mysql2, on the server at the url of MYSQL_URL, when it is set, in a
  # database of this process, see MysqlDatabase. Each pool has two connections: the one that a query is read on, which
  # it checks out of the pool, and the one of the caller, which the block that the rows are yielded to queries on, see
  # `IOStreams::Query#open`.
  #
  # The file of the SQLite database, and its WAL files, are removed once the tests have run, after every connection to
  # them is closed, rather than at exit, which would run before the tests do, since Minitest runs them at exit too.
  def self.configs
    configs = {}
    if driver?("sqlite3", "activerecord-jdbcsqlite3-adapter")
      file = File.join(Dir.tmpdir, "iostreams_query_#{Process.pid}.sqlite3")
      Minitest.after_run do
        ActiveRecord::Base.connection_handler.connection_pool_list(:all).each(&:disconnect!)
        FileUtils.rm_f([file, "#{file}-wal", "#{file}-shm"])
      end
      configs["SQLite"] = {adapter: "sqlite3", database: file, pool: 2}
    end
    if PostgresqlSchema.url && driver?("pg", "activerecord-jdbcpostgresql-adapter")
      configs["PostgreSQL"] = PostgresqlSchema.config
    end
    configs["MySQL"] = MysqlDatabase.config if MysqlDatabase.url && driver?("mysql2", "activerecord-jdbcmysql-adapter")
    configs
  end

  # Returns [true|false] whether Active Record and the driver of one of the supplied names can be loaded: the C extension
  # of the database, or on JRuby, which cannot load it, the adapter of AR-JDBC.
  def self.driver?(*names)
    return false unless defined?(ActiveRecord)

    names.any? do |name|
      require name
      true
    rescue LoadError
      false
    end
  end

  # Returns [Database|nil] the database of the supplied name, when the tests can read it.
  def self.find(name)
    all.find { |database| database.name == name }
  end

  # Returns [Array<Database>] the databases that the tests can read, each set up once. A database that cannot be set up,
  # such as a PostgreSQL server that cannot be reached, is left out, so that only its own tests do not run, see
  # .failures.
  def self.all
    @all ||= configs.filter_map do |name, config|
      build(name, config)
    rescue StandardError => e
      warn("The #{name} query tests do not run, since their database could not be set up: #{e.class}: #{e.message}")
      failures[name] = e
      nil
    end
  end

  # Returns [Hash<String, Exception>] the exception that each database raised that could not be set up, see .all and
  # QueryDatabaseTest.
  def self.failures
    @failures ||= {}
  end

  # Yields each database that the tests can read, see .all.
  def self.each(&)
    all.each(&)
  end

  # Returns [Database] the first database, for the tests that do not depend on the database.
  def self.first
    all.first
  end

  # Returns [Database] an in-memory SQLite database, set up the first time, which is a database of its own on each
  # connection, unlike those of .all.
  def self.memory
    @memory ||= build("SQLiteMemory", {adapter: "sqlite3", database: ":memory:", pool: 2})
  end

  def self.build(name, config)
    configure_active_record
    namespace = Module.new
    const_set(name.gsub(/\W/, ""), namespace)

    namespace.const_set(:Record, Class.new(ActiveRecord::Base) { self.abstract_class = true })
    config = MysqlDatabase.create(config) if name == "MySQL"
    namespace::Record.establish_connection(config)
    # The PostgreSQL adapter of AR-JDBC casts an array with a connection of ActiveRecord::Base, whatever the model,
    # which `pluck` raises for when ActiveRecord::Base has none, see https://github.com/jruby/activerecord-jdbc-adapter/issues/1229.
    ActiveRecord::Base.establish_connection(config) if jdbc? && name == "PostgreSQL"
    namespace::Record.with_connection do |connection|
      PostgresqlSchema.create(connection) if connection.adapter_name == "PostgreSQL"
      create_tables(connection)
    end

    namespace.const_set(:Customer, Class.new(namespace::Record))
    namespace::Customer.class_eval do
      self.table_name = "customers"
      has_many :orders, class_name: "#{namespace.name}::Order"
    end

    namespace.const_set(:Order, Class.new(namespace::Record))
    namespace::Order.class_eval do
      self.table_name = "orders"
      belongs_to :customer, class_name: "#{namespace.name}::Customer", optional: true
      enum :status, {pending: 0, shipped: 1}
      encrypts :secret
      serialize :tags, coder: JSON
    end

    Database.new(name, namespace, config)
  end

  # Active Record as a Rails app sets it up: times in the time zone of the app, and encrypted attributes.
  def self.configure_active_record
    return if @configured

    ActiveRecord::Base.time_zone_aware_attributes = true
    Time.zone_default = Time.find_zone!("America/New_York")
    ActiveRecord::Encryption.configure(
      primary_key:         "iostreams query test primary key",
      deterministic_key:   "iostreams query test deterministic key",
      key_derivation_salt: "iostreams query test salt"
    )
    @configured = true
  end

  def self.create_tables(connection)
    connection.create_table(:customers, force: true) do |t|
      t.string :name, null: false
      t.string :region
    end
    connection.create_table(:orders, force: true) do |t|
      t.references :customer
      t.string :name, null: false
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.integer :status, null: false, default: 0
      t.date :shipped_on
      t.datetime :paid_at
      t.boolean :paid
      t.float :weight
      t.text :notes
      t.json :data
      t.text :tags
      t.string :secret
    end
  end

  # Inserts the rows that the tests read.
  def self.load(database)
    acme   = database.customer.create!(name: "Acme", region: "west")
    globex = database.customer.create!(name: "Globex")
    database.order.create!(
      customer: acme, name: "a", amount: "12.5", status: :shipped, shipped_on: Date.new(2026, 10, 1),
      paid_at: Time.utc(2026, 10, 2, 3, 4, 5.123456r), paid: true, weight: 1.5, notes: "first, \"quoted\"",
      data: {"x" => 1}, tags: %w[a b], secret: "s1"
    )
    database.order.create!(customer: globex, name: "b", amount: "3", paid: false, data: [1, 2])
    database.order.create!(name: "c", amount: "100.25", status: :shipped, shipped_on: Date.new(1969, 12, 31))
  end
end

module QueryDatabase
  # The schema of this process on the PostgreSQL database at the url of POSTGRES_URL, such as
  # `postgres://postgres:postgres@localhost:5432/iostreams_test`, which CI reads, that the tests create their tables and
  # types in, and replace their rows in, see QueryDatabase.configs.
  #
  # Each test process creates a schema of its own, and drops it once its tests have run, so that test processes that read
  # the same database at once, such as in two worktrees, do not change each other's rows, and the tables of the database
  # are never changed. The tests refuse a database whose name is not that of a database for tests, such as one that
  # POSTGRES_URL names for another application.
  module PostgresqlSchema
    # The password of the role of this process, see .role.
    PASSWORD = "iostreams"

    # Returns [String] the url of POSTGRES_URL, or nil when it is not set.
    def self.url
      ENV.fetch("POSTGRES_URL", nil)
    end

    # Returns [Hash] the configuration of the pool of the database, whose connections search only the schema of this
    # process, see .schema_name, and give up on a server that cannot be reached within 5 seconds, unless the url says
    # otherwise.
    def self.config
      {url: url, pool: 2, schema_search_path: schema_name, connect_timeout: 5}
    end

    # Returns [String] the name of the schema of this process.
    def self.schema_name
      @schema_name ||= "iostreams_#{Process.pid}_#{SecureRandom.hex(3)}"
    end

    # Creates the schema of this process on the connection, and drops it, and the role of this process, see .role, once
    # the tests have run.
    #
    # Raises ArgumentError, before anything is changed, when the database is not one for tests, see TEST_DATABASE, or the
    # connection does not search only the schema of this process, such as for a url that sets `schema_search_path`.
    def self.create(connection)
      database = connection.current_database
      unless TEST_DATABASE.match?(database)
        raise(ArgumentError, "POSTGRES_URL names the database #{database.inspect}, which the query tests do not change, " \
                             "since its name is not that of a database for tests, such as iostreams_test")
      end
      unless connection.schema_search_path == schema_name
        raise(ArgumentError, "POSTGRES_URL sets the schema_search_path, which the query tests set to a schema of their own")
      end

      connection.create_schema(schema_name)
      Minitest.after_run { drop(connection.pool) }
    end

    # Returns [String] the name of a role of this process, created once, which may not log in, though its password is
    # PASSWORD, and may use the schema of this process, but not read its tables. Its name starts with that of the
    # database, so that a message of PostgreSQL that names the role also names the database.
    def self.role(connection)
      @role ||= begin
        name   = "#{connection.current_database}_#{schema_name}"
        quoted = connection.quote_column_name(name)
        connection.execute("CREATE ROLE #{quoted} NOLOGIN PASSWORD #{connection.quote(PASSWORD)}")
        connection.execute("GRANT USAGE ON SCHEMA #{connection.quote_column_name(schema_name)} TO #{quoted}")
        name
      end
    end

    # Drops the schema of this process, with its tables and types, and then the role of this process, which may use it.
    def self.drop(pool)
      pool.with_connection do |connection|
        connection.drop_schema(schema_name, if_exists: true)
        connection.execute("DROP ROLE IF EXISTS #{connection.quote_column_name(@role)}") if @role
      end
    rescue StandardError => e
      warn("The query tests could not drop the PostgreSQL schema #{schema_name}: #{e.class}: #{e.message}")
    end
    private_class_method :drop
  end
end

module QueryDatabase
  # The database of this process on the MySQL server at the url of MYSQL_URL, such as
  # `mysql2://root:mysql@127.0.0.1:3306/iostreams_test`, which CI reads, that the tests create their tables in, and
  # replace their rows in, see QueryDatabase.configs.
  #
  # A database of MySQL has no schemas, so each test process creates a database of its own, named after the one of the
  # url, such as `iostreams_test_1a2b3c4d`, and drops it once its tests have run, so that test processes that read the
  # same server at once, such as in two worktrees, do not change each other's rows, and the database of the url is never
  # changed. The tests refuse a url whose database is not named as one for tests, see TEST_DATABASE, such as one that
  # MYSQL_URL names for another application.
  module MysqlDatabase
    # Returns [String] the url of MYSQL_URL, or nil when it is not set.
    def self.url
      ENV.fetch("MYSQL_URL", nil)
    end

    # The configuration of the MySQL adapter of AR-JDBC on JRuby:
    #   properties: those of Connector/J, its driver, that connect a user of `caching_sha2_password`, the default of
    #   MySQL 8, without TLS, and that read a YEAR as an integer, as mysql2 does, rather than as a date, which the
    #   integer type of Active Record raises for, as `pluck` does, see https://github.com/jruby/activerecord-jdbc-adapter/issues/1234.
    #   statement_limit: 0, which keeps no prepared statement, since AR-JDBC keeps those of a connection that the server
    #   ended, such as one that the tests kill, which raise "No operations allowed after statement closed" once, see
    #   https://github.com/jruby/activerecord-jdbc-adapter/issues/1228.
    JDBC_CONFIG = {
      properties:      {"allowPublicKeyRetrieval" => "true", "useSSL" => "false", "yearIsDateType" => "false"}.freeze,
      statement_limit: 0
    }.freeze

    # Returns [Hash] the configuration of the pool of the database, whose connections give up on a server that cannot be
    # reached within CONNECT_TIMEOUT seconds, with the JDBC_CONFIG on JRuby. Its url names the database of the url until
    # the database of this process is created, see .create.
    def self.config
      config = {url: url, pool: 2, connect_timeout: CONNECT_TIMEOUT}
      QueryDatabase.jdbc? ? config.merge(JDBC_CONFIG) : config
    end

    # Returns [String] the suffix of the names of this process, those of its database, see .create, and of the users
    # that its tests create, see .user.
    def self.suffix
      @suffix ||= SecureRandom.hex(4)
    end

    # Returns [String] the name of a user of MySQL of this process with the supplied role, such as "reader", since a
    # user belongs to the server rather than to a database, so that the tests of two processes at once do not share it.
    def self.user(role)
      "iostreams_#{role}_#{suffix}"
    end

    # Creates the database of this process on the server of the url of the configuration, which is dropped once the
    # tests have run.
    #
    # Returns [Hash] the configuration, with the url of the database of this process.
    #
    # Raises ArgumentError, before anything is changed, when the url does not name a database for tests, see
    # TEST_DATABASE.
    def self.create(config)
      url  = URI(config.fetch(:url))
      name = url.path.delete_prefix("/")
      unless TEST_DATABASE.match?(name)
        raise(ArgumentError, "MYSQL_URL names the database #{name.inspect}, beside which the query tests do not create " \
                             "a database of their own, since its name is not that of a database for tests, such as " \
                             "iostreams_test")
      end

      database    = "#{name}_#{suffix}"
      server      = url.dup
      server.path = ""
      record      = QueryDatabase.const_set(:MysqlServer, Class.new(ActiveRecord::Base) { self.abstract_class = true })
      record.establish_connection(url: server.to_s, pool: 1, connect_timeout: CONNECT_TIMEOUT,
                                  **config.slice(*JDBC_CONFIG.keys))
      record.with_connection { |connection| connection.create_database(database) }
      Minitest.after_run { drop(record, database) }
      url.path = "/#{database}"
      config.merge(url: url.to_s)
    end

    # Drops the database of this process, on a connection to its server without a database.
    def self.drop(record, database)
      record.with_connection { |connection| connection.drop_database(database) }
    rescue StandardError => e
      warn("The query tests could not drop the MySQL database #{database}: #{e.class}: #{e.message}")
    end
    private_class_method :drop
  end
end

# The methods of the tests of a query.
module QueryTestMethods
  # Returns [Array] the rows or records that the stream reads in the supplied mode.
  def each(stream, mode = :hash, **)
    list = []
    stream.each(mode, **) { |row| list << row }
    list
  end

  # Returns [Array] the binds of the payload of an `sql.active_record` event, type cast for the driver, which AR-JDBC
  # reports as a Proc that returns them, as Active Record allows.
  def type_casted_binds(payload)
    binds = payload[:type_casted_binds]
    binds.respond_to?(:call) ? binds.call : binds
  end

  # Returns [Array<String>] the names of the SQL statements that Active Record runs within the block.
  def statements(&)
    names    = []
    callback = ->(_name, _start, _finish, _id, payload) { names << payload[:name] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &)
    names
  end
end
