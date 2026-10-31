# frozen_string_literal: true

require_relative "query_helper"

# The types of the columns of a query, on each database of QueryDatabase: the type that casts each column, as `pluck`
# chooses it, see `IOStreams::Query::CastTypes`.
class ColumnTypesTest < Minitest::Test
  # A whole number of cents, the value of an attribute of a type of the application.
  Cents = Struct.new(:value) do
    def to_s = format("%.2f", value.fdiv(100))
  end

  # A type of the application, whose values are Cents rather than the Integers of the type that it extends.
  class CentsType < ActiveModel::Type::Integer
    def deserialize(value)
      cents = super
      cents && Cents.new(cents)
    end

    def cast(value)
      return value if value.is_a?(Cents)

      cents = super
      cents && Cents.new(cents)
    end

    # Rather than super, which casts it again in Active Model 7.2.
    def serialize(value)
      value.is_a?(Cents) ? value.value : value
    end
  end

  # The models of these tests on a database, in a namespace of their own: a Buyer, of a Region, whose `status` enum has
  # other values than the one of a Purchase, which is of a Buyer, and has attributes that Active Record decorates, and
  # one of a type of the application. The warehouses table has no model.
  module Models
    # Returns [Module] the namespace of the models on the database, once it creates their tables.
    def self.build(database)
      namespace = const_set(database.name.gsub(/\W/, ""), Module.new)
      database.record.with_connection { |connection| create_tables(connection) }
      record = database.record

      namespace.const_set(:Region, Class.new(record))
      namespace::Region.class_eval do
        self.table_name = "regions"
        enum :zone, {north: 0, south: 1}
      end

      namespace.const_set(:Buyer, Class.new(record))
      namespace::Buyer.class_eval do
        self.table_name = "buyers"
        belongs_to :region, class_name: "#{namespace.name}::Region", optional: true
        enum :tier, {silver: 0, gold: 1}
        enum :status, {active: 0, closed: 1, suspended: 2}
        encrypts :ssn
      end

      namespace.const_set(:Purchase, Class.new(record))
      namespace::Purchase.class_eval do
        self.table_name = "purchases"
        belongs_to :buyer, class_name: "#{namespace.name}::Buyer", optional: true
        enum :status, {pending: 0, shipped: 1}
        # In the order that the Rails guide gives, so that the serialized attribute is encrypted.
        serialize :payload, coder: JSON
        encrypts :payload
        enum :kind, {plain: 0, rich: 1}
        normalizes :kind, with: ->(kind) { kind.to_s.strip }
        attribute :cents, CentsType.new
      end

      define_shift(namespace, record)
      namespace
    end

    # Defines the model of the shifts, whose table has a time of day, in the namespace.
    def self.define_shift(namespace, record)
      namespace.const_set(:Shift, Class.new(record) { self.table_name = "shifts" })
    end

    def self.create_tables(connection)
      connection.create_table(:regions, force: true) do |t|
        t.integer :zone
      end
      connection.create_table(:buyers, force: true) do |t|
        t.references :region
        t.integer :tier
        t.integer :status
        t.string :ssn
        t.datetime :joined_at
      end
      connection.create_table(:purchases, force: true) do |t|
        t.references :buyer
        t.integer :status, null: false, default: 0
        t.text :payload
        t.integer :kind, null: false, default: 0
        t.integer :cents
        t.decimal :quantity, precision: 20, scale: 0
        t.decimal :units, precision: 18, scale: 0
        t.integer :items, null: false, default: 0
        t.decimal :price, precision: 10, scale: 2, null: false, default: 0
        t.boolean :gift, null: false, default: false
        t.date :due_on, null: false, default: "2026-01-01"
      end
      connection.create_table(:warehouses, force: true) do |t|
        t.references :purchase
        t.datetime :opened_at
      end
      connection.create_table(:shifts, force: true) do |t|
        # With microseconds, which a TIME of MySQL leaves out by default.
        t.time :starts_at, precision: 6
      end
    end

    # Replaces the rows of the tables: a purchase of a buyer who is closed, in a region, one of a buyer who is suspended,
    # and one without a buyer, the first of them in a warehouse.
    def self.load(models)
      models::Purchase.delete_all
      models::Buyer.delete_all
      models::Region.delete_all
      models::Purchase.with_connection { |connection| connection.execute("DELETE FROM warehouses") }
      models::Shift.delete_all

      west    = models::Region.create!(zone: :south)
      acme    = models::Buyer.create!(region: west, tier: :gold, status: :closed, ssn: "123-45-6789",
                                      joined_at: Time.utc(2026, 1, 2, 3, 4, 5.25r))
      globex  = models::Buyer.create!(tier: :silver, status: :suspended)
      # A quantity of more digits than a 64-bit integer holds, which a double holds exactly, since SQLite stores it as one.
      shipped = models::Purchase.create!(buyer: acme, status: :shipped, payload: {"a" => 1}, kind: :rich, cents: 1250,
                                         quantity: 10**19, units: 123_456_789_012_345_678)
      models::Purchase.create!(buyer: globex, payload: [1, 2], cents: 0)
      models::Purchase.create!
      models::Purchase.with_connection do |connection|
        connection.execute("INSERT INTO warehouses (purchase_id, opened_at) VALUES (#{shipped.id}, '2026-05-06 07:08:09')")
      end
    end
  end

  QueryDatabase.each do |database|
    models = Models.build(database)

    describe "#{IOStreams::Query::CastTypes.name} on #{database.name}" do
      let(:purchases) { models::Purchase.order("purchases.id") }
      let(:buyers) { models::Buyer.arel_table }

      before { Models.load(models) }

      # Asserts that the rows of the query of the columns of the relation are those that `pluck` returns, and of the same
      # classes, such as an `ActiveSupport::TimeWithZone` rather than a `Time`, which are equal.
      def assert_plucked(relation, *columns)
        rows = []
        IOStreams.stream(relation.select(*columns)).each(:array) { |row| rows << row }
        header   = rows.shift
        expected = relation.pluck(*columns)
        # Which pluck returns as the values themselves.
        expected = expected.map { |value| [value] } if header.size == 1

        assert_equal expected, rows
        assert_equal(expected.map { |row| row.map(&:class) }, rows.map { |row| row.map(&:class) })
      end

      it "casts an enum of a joined model by its names" do
        assert_plucked purchases.joins(:buyer), "purchases.id", "buyers.tier"
        assert_equal %w[gold silver], purchases.joins(:buyer).pluck("buyers.tier")
      end

      it "casts an encrypted attribute of a joined model as its plain text" do
        assert_plucked purchases.joins(:buyer), "purchases.id", "buyers.ssn"
        assert_equal ["123-45-6789", nil], purchases.joins(:buyer).pluck("buyers.ssn")
      end

      it "casts a column of a joined model by its own enum, rather than by one of the same name of the model" do
        assert_plucked purchases.joins(:buyer), "purchases.id", "buyers.status"
        assert_equal %w[closed suspended], purchases.joins(:buyer).pluck("buyers.status")
      end

      it "casts an attribute of Arel of a joined table" do
        assert_plucked purchases.joins(:buyer), models::Purchase.arel_table[:id], buyers[:tier], buyers[:status]
        assert_plucked purchases.joins(:buyer), buyers[:status].as("buyer_status")
      end

      it "casts a datetime of a joined model in the time zone of the app" do
        assert_plucked purchases.joins(:buyer), "purchases.id", "buyers.joined_at"
        assert_instance_of ActiveSupport::TimeWithZone, purchases.joins(:buyer).pluck("buyers.joined_at").first
      end

      it "casts a column that only a joined model has by its name, through left joins and nested joins too" do
        assert_plucked purchases.joins(:buyer), "purchases.id", "tier"
        assert_plucked purchases.left_joins(:buyer), "purchases.id", "tier"
        assert_plucked purchases.joins(buyer: :region), "purchases.id", "zone"
      end

      it "casts the joins of a relation of another model that it merges" do
        merged = purchases.joins(:buyer).merge(models::Buyer.joins(:region))

        assert_plucked merged, "purchases.id", "zone"
        assert_plucked merged, "purchases.id", "regions.zone"
        assert_equal %w[south], merged.pluck("zone")
      end

      it "casts a table joined with SQL as pluck does: by its association, by the schema, or not at all" do
        sql = purchases.joins("INNER JOIN buyers ON buyers.id = purchases.buyer_id")

        # The association that is named as the table casts its columns, while a column by its name is not cast.
        assert_plucked sql, "purchases.id", "buyers.tier"
        assert_plucked sql, "purchases.id", "tier"
        assert_equal [["gold", 1], ["silver", 0]], sql.pluck("buyers.tier", Arel.sql("tier AS raw_tier"))

        # A table without a model is cast by the type of its column, which is not in the time zone of the app.
        warehouses = purchases.joins("INNER JOIN warehouses ON warehouses.purchase_id = purchases.id")

        assert_plucked warehouses, "purchases.id", "warehouses.opened_at"
        assert_equal [Time.utc(2026, 5, 6, 7, 8, 9)], warehouses.pluck("warehouses.opened_at")
      end

      it "casts by the name of each column, as pluck does, when a selected value is several columns" do
        assert_plucked purchases.joins(:buyer), Arel.sql("purchases.id, buyers.tier")
        assert_plucked purchases.joins(:buyer), Arel.sql("purchases.id, purchases.status"), "buyers.tier"
        assert_equal [[1, "shipped"], [0, "pending"]], purchases.joins(:buyer).pluck(Arel.sql("buyers.tier, purchases.status"))
      end
    end

    describe "#{IOStreams::Query::Columns.name} on #{database.name}" do
      let(:purchases) { models::Purchase.order(:id) }

      before { Models.load(models) }

      # Returns [Hash] the field of the schema of the query of the column, by its name.
      def field(relation, name)
        IOStreams.stream(relation.select(:id, name)).infer_schema.to_h[:fields].find { |field| field[:name] == name.to_s }
      end

      # Returns [Array<Hash>] the records of the query.
      def records(relation)
        records = []
        IOStreams.stream(relation).each(:hash) { |record| records << record }
        records
      end

      it "reads a serialized attribute that is encrypted as any value, as pluck returns it" do
        assert_equal({name: "payload", type: "any"}, field(purchases, :payload))
        assert_equal(purchases.pluck(:payload), records(purchases.select(:payload)).map { |record| record["payload"] })
        assert_equal [{"a" => 1}, [1, 2], nil], purchases.pluck(:payload)
      end

      it "reads an enum that is normalized as the names of its values, which a column that is never null does not require" do
        assert_equal({name: "kind", type: "string"}, field(purchases, :kind))
        assert_equal(%w[rich plain plain], records(purchases.select(:kind)).map { |record| record["kind"] })
      end

      it "reads an attribute of a type of the application as any value, since it may not be of the type that it answers" do
        assert_equal({name: "cents", type: "any"}, field(purchases, :cents))
        assert_equal([Cents.new(1250), Cents.new(0), nil], records(purchases.select(:cents)).map { |record| record["cents"] })
      end

      it "copies them to CSV" do
        output = StringIO.new
        IOStreams.stream(output).format(:csv).copy_from(purchases.select(:payload, :kind, :cents), mode: :hash)

        assert_equal "payload,kind,cents\n\"{\"\"a\"\":1}\",rich,12.50\n\"[1,2]\",plain,0.00\n,plain,\n", output.string
      end

      it "reads a value of a column that is never null as nil, as pluck does, when SQLite holds one not of its type" do
        skip "Only a column of SQLite holds a value of any type" unless database.name == "SQLite"

        models::Purchase.with_connection do |connection|
          connection.execute("UPDATE purchases SET items = '', price = '', gift = '', due_on = 'soon' WHERE buyer_id IS NULL")
        end
        relation = purchases.select(:id, :items, :price, :gift, :due_on)

        assert_empty IOStreams::Query::SqliteStatement.requirable_types
        assert_empty(IOStreams.stream(relation).infer_schema.to_h[:fields].select { |field| field[:constraints] })
        assert_equal relation.pluck(:id, :items, :price, :gift, :due_on), records(relation).map(&:values)
        assert_equal [nil, nil, nil, nil], relation.pluck(:items, :price, :gift, :due_on).last
      end

      it "describes a decimal without a scale as a number without decimals when it holds more digits than a 64-bit integer" do
        assert_equal({name: "quantity", type: "number", decimals: 0}, field(purchases, :quantity))
        assert_equal({name: "units", type: "integer"}, field(purchases, :units))
        # A BigDecimal, as a number is, of the Integer that pluck returns.
        quantity = records(purchases.select(:quantity)).first["quantity"]

        assert_instance_of BigDecimal, quantity
        assert_equal purchases.pluck(:quantity).first, quantity
        assert_equal 10**19, quantity
      end

      describe "a time of day" do
        let(:shifts) { models::Shift.order(:id) }

        before do
          # In the time zone of the app, America/New_York, which Rails stores in UTC on 2000-01-01, so that 22:00 is
          # stored as 03:00, which Active Record reads as 22:00 on 1999-12-31.
          models::Shift.create!(starts_at: "09:30")
          models::Shift.create!(starts_at: "22:00:15.25")
          models::Shift.create!
        end

        it "is a time, of the clock of the app, on 2000-01-01" do
          assert_equal({name: "starts_at", type: "time"}, field(shifts, :starts_at))
          assert_equal(
            [Time.new(2000, 1, 1, 9, 30, 0, "-05:00"), Time.new(2000, 1, 1, 22, 0, 15.25r, "-05:00"), nil],
            records(shifts.select(:starts_at)).map { |record| record["starts_at"] }
          )
          # The time of the clock that pluck returns, on 1999-12-31 for 22:00.
          assert_equal(["09:30", "22:00", nil], shifts.pluck(:starts_at).map { |time| time&.strftime("%H:%M") })
        end

        it "copies it as the time of its clock to CSV and JSON" do
          csv  = StringIO.new
          json = StringIO.new
          IOStreams.stream(csv).format(:csv).copy_from(shifts.select(:starts_at), mode: :hash)
          IOStreams.stream(json).format(:json).copy_from(shifts.select(:starts_at), mode: :hash)

          assert_equal "starts_at\n09:30:00\n22:00:15.250\n\n", csv.string
          assert_equal %({"starts_at":"09:30:00"}\n{"starts_at":"22:00:15.250"}\n{"starts_at":null}\n), json.string
        end

        it "copies it to Parquet as the time of its clock" do
          skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "shifts.parquet")
            path.copy_from(shifts.select(:starts_at), mode: :hash)
            times = []
            path.each(:hash) { |record| times << record&.fetch("starts_at") }

            # The last record, whose only value is null, is a blank row.
            assert_equal [Time.utc(2000, 1, 1, 9, 30), Time.utc(2000, 1, 1, 22, 0, 15.25r), nil], times
          end
        end

        it "raises for a time outside a day, rather than read it as nil, or as the start of the next day" do
          models::Shift.with_connection { |connection| connection.execute("INSERT INTO shifts (starts_at) VALUES ('24:00:00')") }
          if QueryDatabase.jdbc? && database.name != "SQLite"
            # The drivers of AR-JDBC raise for it themselves, as pluck does on JRuby: Connector/J that it is not a TIME,
            # and PgJDBC, through Joda-Time, that it is not an hour of a day.
            [shifts.select(:starts_at), shifts.select(:starts_at).in_batches(of: 2)].each do |query|
              error = assert_raises(StandardError, Java::JavaLang::RuntimeException) { records(query) }
              assert_match(/is an invalid TIME value|Value 24 for hourOfDay must be in the range/, error.message)
            end
          else
            error = assert_raises(IOStreams::Errors::InvalidValue) { records(shifts.select(:starts_at)) }
            assert_match(/\AColumn "starts_at": .*24:00:00.* is not a time of day, from 00:00:00 to 23:59:59/, error.message)
            assert_raises(IOStreams::Errors::InvalidValue) { records(shifts.select(:starts_at).in_batches(of: 2)) }
          end
        end
      end

      it "copies a decimal of more digits than a 64-bit integer to CSV, JSON and Parquet" do
        relation = purchases.where.not(quantity: nil).select(:quantity, :units)
        csv      = StringIO.new
        json     = StringIO.new
        IOStreams.stream(csv).format(:csv).copy_from(relation, mode: :hash)
        IOStreams.stream(json).format(:json).copy_from(relation, mode: :hash)

        assert_equal "quantity,units\n10000000000000000000,123456789012345678\n", csv.string
        assert_equal "{\"quantity\":10000000000000000000,\"units\":123456789012345678}\n", json.string
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "purchases.parquet")
          path.copy_from(relation, mode: :hash)
          records = []
          path.schema(IOStreams.stream(relation).infer_schema).each(:hash) { |record| records << record }

          assert_equal [{"quantity" => 10**19, "units" => 123_456_789_012_345_678}], records
        end
      end
    end
  end

  describe IOStreams::Query::Columns do
    # Returns [Hash] the field of the schema of a column of the type.
    def field(type)
      IOStreams::Query::Columns.new(names: ["c"], types: [type], not_null: [false], requirable_types: []).schema[:fields].first
    end

    it "looks through the decorators of Active Record to the type within them" do
      time_zone = ActiveRecord::AttributeMethods::TimeZoneConversion::TimeZoneConverter.new(ActiveRecord::Type::DateTime.new)

      assert_equal({name: "c", type: "datetime"}, field(time_zone))
      # Active Record defines LockingType with its optimistic locking, which it loads with its first model, which JRuby,
      # without a driver of a database, never builds.
      locking = ActiveRecord::Locking::Optimistic && ActiveRecord::Locking::LockingType

      assert_equal({name: "c", type: "integer"}, field(locking.new(ActiveModel::Type::Integer.new)))
    end

    it "does not look through a decorator of the application, nor trust a type of its own" do
      assert_equal({name: "c", type: "any"}, field(SimpleDelegator.new(ActiveModel::Type::Integer.new)))
      assert_equal({name: "c", type: "any"}, field(CentsType.new))
    end

    it "describes an integer of more digits than a 64-bit integer holds as a number without decimals" do
      assert_equal({name: "c", type: "number", decimals: 0}, field(ActiveRecord::Type::DecimalWithoutScale.new(precision: 19)))
      assert_equal({name: "c", type: "integer"}, field(ActiveRecord::Type::DecimalWithoutScale.new(precision: 18)))
      assert_equal({name: "c", type: "integer"}, field(ActiveModel::Type::Integer.new(limit: 8)))
    end

    it "describes an unsigned integer of 8 bytes, whose values a 64-bit integer cannot all hold, as a number without decimals" do
      assert_equal({name: "c", type: "number", decimals: 0}, field(ActiveRecord::Type::UnsignedInteger.new(limit: 8)))
      assert_equal({name: "c", type: "integer"}, field(ActiveRecord::Type::UnsignedInteger.new(limit: 4)))
      assert_equal({name: "c", type: "integer"}, field(ActiveRecord::Type::UnsignedInteger.new))
    end
  end
end
