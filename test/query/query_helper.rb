# frozen_string_literal: true

require_relative "../test_helper"
require "json"
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
  # cannot be loaded, as on JRuby, and PostgreSQL, at the url of POSTGRES_URL, such as
  # `postgres://postgres:postgres@localhost:5432/iostreams_test`, when it is set. Each pool has two connections: the
  # one that a query is read on, which it checks out of the pool, and the one of the caller, which the block that the
  # rows are yielded to queries on, see `IOStreams::Query#open`.
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
    configs["PostgreSQL"] = {url: ENV.fetch("POSTGRES_URL"), pool: 2} if ENV["POSTGRES_URL"] && driver?("pg")
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

  # Returns [Array<Database>] the databases that the tests can read, each set up once.
  def self.all
    @all ||= configs.map { |name, config| build(name, config) }
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
    namespace::Record.with_connection { |connection| create_tables(connection) }

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
