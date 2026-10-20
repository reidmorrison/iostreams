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
  # A database, and the namespace of its models: `Record`, its abstract base class, `Customer` and `Order`.
  Database = Struct.new(:name, :namespace) do
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
  end

  # Returns [Hash<String, Hash>] the configuration of each database that the tests can read: SQLite, unless its gem
  # cannot be loaded, as on JRuby, PostgreSQL, at the url of POSTGRES_URL, when it is set, in a schema of this
  # process, see PostgresqlSchema, and MySQL with mysql2, at the url of MYSQL_URL, such as
  # `mysql2://root:mysql@127.0.0.1:3306/iostreams_test`, when it is set. Each pool has two connections: the one that a query is read on, which it checks out
  # of the pool, and the one of the caller, which the block that the rows are yielded to queries on, see
  # `IOStreams::Query#open`.
  #
  # The file of the SQLite database, and its WAL files, are removed once the tests have run, after every connection to
  # them is closed, rather than at exit, which would run before the tests do, since Minitest runs them at exit too.
  def self.configs
    configs = {}
    if driver?("sqlite3")
      file = File.join(Dir.tmpdir, "iostreams_query_#{Process.pid}.sqlite3")
      Minitest.after_run do
        ActiveRecord::Base.connection_handler.connection_pool_list(:all).each(&:disconnect!)
        FileUtils.rm_f([file, "#{file}-wal", "#{file}-shm"])
      end
      configs["SQLite"] = {adapter: "sqlite3", database: file, pool: 2}
    end
    configs["PostgreSQL"] = PostgresqlSchema.config if PostgresqlSchema.url && driver?("pg")
    configs["MySQL"]      = {url: ENV.fetch("MYSQL_URL"), pool: 2} if ENV["MYSQL_URL"] && driver?("mysql2")
    configs
  end

  # Returns [true|false] whether Active Record and the driver of the supplied name can be loaded.
  def self.driver?(name)
    return false unless defined?(ActiveRecord)

    require name
    true
  rescue LoadError
    false
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
    namespace::Record.establish_connection(config)
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

    Database.new(name, namespace)
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
    # The name of a database for tests: one for IOStreams, such as `iostreams_test`, or one for tests, such as `test` or
    # `myapp_test`.
    TEST_DATABASE = /\Aiostreams|(?:\A|_)test\z/

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

# The methods of the tests of a query.
module QueryTestMethods
  # Returns [Array] the rows or records that the stream reads in the supplied mode.
  def each(stream, mode = :hash, **)
    list = []
    stream.each(mode, **) { |row| list << row }
    list
  end

  # Returns [Array<String>] the names of the SQL statements that Active Record runs within the block.
  def statements(&)
    names    = []
    callback = ->(_name, _start, _finish, _id, payload) { names << payload[:name] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &)
    names
  end
end
