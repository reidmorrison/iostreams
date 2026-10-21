# frozen_string_literal: true

require_relative "query_helper"

# The types of the columns of a query, on each database of QueryDatabase: the type that casts each column, as `pluck`
# chooses it, see `IOStreams::Query::CastTypes`.
class ColumnTypesTest < Minitest::Test
  # The models of these tests on a database, in a namespace of their own: a Buyer, of a Region, whose `status` enum has
  # other values than the one of a Purchase, which is of a Buyer. The warehouses table has no model.
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
      end
      namespace
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
      end
      connection.create_table(:warehouses, force: true) do |t|
        t.references :purchase
        t.datetime :opened_at
      end
    end

    # Replaces the rows of the tables: a purchase of a buyer who is closed, in a region, one of a buyer who is suspended,
    # and one without a buyer, the first of them in a warehouse.
    def self.load(models)
      models::Purchase.delete_all
      models::Buyer.delete_all
      models::Region.delete_all
      models::Purchase.with_connection { |connection| connection.execute("DELETE FROM warehouses") }

      west    = models::Region.create!(zone: :south)
      acme    = models::Buyer.create!(region: west, tier: :gold, status: :closed, ssn: "123-45-6789",
                                      joined_at: Time.utc(2026, 1, 2, 3, 4, 5.25r))
      globex  = models::Buyer.create!(tier: :silver, status: :suspended)
      shipped = models::Purchase.create!(buyer: acme, status: :shipped)
      models::Purchase.create!(buyer: globex)
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
        assert_plucked purchases.joins(:buyer), Arel.sql("purchases.*"), "buyers.tier"
        assert_equal [[1, "shipped"], [0, "pending"]], purchases.joins(:buyer).pluck(Arel.sql("buyers.tier, purchases.status"))
      end
    end
  end
end
