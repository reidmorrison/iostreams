# frozen_string_literal: true

require_relative "query_helper"

# Reads a query in the batches of Rails, see `IOStreams::Query::Batches`, on each database of QueryDatabase.
class BatchesTest < Minitest::Test
  # Returns [Array<Class>] the models of the tables of these tests on the database, which are created the first time:
  # a line, whose primary key has two columns, and an event, which has no primary key, whose rows a unique index tells
  # apart.
  def self.models(database)
    @models ||= {}
    @models[database.name] ||= begin
      database.record.with_connection do |connection|
        connection.create_table(:batch_lines, primary_key: %i[shop_id id], force: true) do |t|
          t.integer :shop_id, null: false
          t.integer :id, null: false
          t.string :name, null: false
        end
        connection.create_table(:batch_events, id: false, force: true) do |t|
          t.string :code, null: false
          t.integer :seq, null: false
          t.index %i[code seq], unique: true
        end
      end
      prefix = database.name.gsub(/\W/, "")
      line   = const_set(:"#{prefix}Line", Class.new(database.record) { self.table_name = "batch_lines" })
      event  = const_set(:"#{prefix}Event", Class.new(database.record) { self.table_name = "batch_events" })
      [line, event]
    end
  end

  QueryDatabase.each do |database|
    describe "#{IOStreams::Query::Batches.name} on #{database.name}" do
      let(:db) { database }
      let(:orders) { db.order.order(:id) }
      let(:line) { BatchesTest.models(db).first }
      let(:event) { BatchesTest.models(db).last }

      before do
        db.load
        line.delete_all
        event.delete_all
      end

      def each(stream, mode = :hash, **)
        list = []
        stream.each(mode, **) { |row| list << row }
        list
      end

      # Returns [Array<String>] the SQL of the queries of the batches that IOStreams reads within the block.
      def batch_sql(&)
        sql      = []
        callback = ->(*, payload) { sql << payload[:sql] if payload[:name] == "IOStreams Batch" }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &)
        sql
      end

      # Adds two orders of the customer Acme, who then has three.
      def add_acme_orders
        acme = db.customer.find_by!(name: "Acme")
        db.order.create!(customer: acme, name: "d", amount: 1)
        db.order.create!(customer: acme, name: "e", amount: 2)
        acme
      end

      describe "a relation that was loaded" do
        it "reads each row once, by the primary keys of the records of each batch" do
          expected = each(IOStreams.stream(db.order.in_batches(of: 2)))
          relation = db.order.all.load
          sql      = batch_sql { assert_equal expected, each(IOStreams.stream(relation.in_batches(of: 2))) }

          assert_equal(orders.ids, expected.map { |order| order["id"] })
          assert_equal 2, sql.size
        end

        it "reads the records that start: and finish: choose" do
          ids      = orders.ids
          relation = db.order.all.load

          assert_equal([ids[1]], each(IOStreams.stream(relation.in_batches(of: 1, start: ids[1], finish: ids[1]))).map { |order| order["id"] })
          assert_equal(ids.drop(1), each(IOStreams.stream(relation.in_batches(of: 1, start: ids[1]))).map { |order| order["id"] })
        end

        it "reads a preloaded association" do
          acme     = add_acme_orders
          customer = db.customer.includes(:orders).find(acme.id)

          assert_predicate customer.orders, :loaded?
          assert_equal(%w[a d e], each(IOStreams.stream(customer.orders.in_batches(of: 2))).map { |order| order["name"] })
        end

        it "reads the rows of a record once, though its joins return it more than once" do
          add_acme_orders
          relation = db.customer.joins(:orders).select("customers.id", "orders.name AS order_name").load
          expected = relation.map { |customer| {"id" => customer.id, "order_name" => customer.order_name} }

          assert_equal 4, expected.size
          assert_equal expected.sort_by(&:values), each(IOStreams.stream(relation.in_batches(of: 2))).sort_by(&:values)
        end

        it "reads the records without the limit and offset of the relation, which chose them" do
          relation = orders.offset(1).limit(2).load

          assert_equal(%w[b c], each(IOStreams.stream(relation.in_batches(of: 1, error_on_ignore: false))).map { |order| order["name"] })
        end

        it "reads a relation of a model whose primary key has two columns" do
          line.insert_all([[2, 1], [1, 2], [1, 1], [3, 1], [2, 2]].map { |shop, id| {shop_id: shop, id: id, name: "#{shop}-#{id}"} })
          expected = [%w[shop_id id name], *line.order(:shop_id, :id).pluck(:shop_id, :id, :name)]

          assert_equal expected, each(IOStreams.stream(line.all.load.in_batches(of: 2)), :array)
          assert_equal expected, each(IOStreams.stream(line.in_batches(of: 2)), :array)
        end

        it "raises when the records have no primary key, by which the batches are read" do
          error = assert_raises(ArgumentError) { each(IOStreams.stream(db.order.select(:name).load.in_batches(of: 2))) }
          assert_equal "The batches of a relation that was loaded are read by the primary keys of their records, which " \
                       "the relation does not select: select id, or read the batches of a relation that is not loaded",
                       error.message

          event.insert_all([{code: "a", seq: 1}, {code: "b", seq: 1}])
          error = assert_raises(ArgumentError) { each(IOStreams.stream(event.all.load.in_batches(of: 2))) }
          assert_equal "#{event.name} has no primary key, by which the batches of a relation that was loaded are " \
                       "read: read the batches of a relation that is not loaded", error.message
        end
      end
    end
  end
end
