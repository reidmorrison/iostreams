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

      describe "batches whose rows Rails reads otherwise than the relation" do
        it "raises for a relation with an offset that is not loaded, since Rails applies it to each batch" do
          error = assert_raises(ArgumentError) { IOStreams.stream(db.order.offset(1).in_batches(of: 2)) }

          assert_equal "A query with an offset cannot be read in batches, since Rails applies the offset to each batch, " \
                       "which skips rows: read it as one query instead, such as with `IOStreams.stream(relation)`",
                       error.message
          assert_equal(%w[b c], each(IOStreams.stream(db.order.order(:id).offset(1))).map { |order| order["name"] })
        end

        it "raises when the stream is created, so that a copy keeps an existing target" do
          Dir.mktmpdir do |dir|
            path = File.join(dir, "orders.csv")
            File.write(path, "previous\n")

            assert_raises(ArgumentError) do
              IOStreams.path(path).copy_from(db.order.select(:name).load.in_batches(of: 2), mode: :hash)
            end
            assert_equal "previous\n", File.read(path)
          end
        end
      end

      describe "a second traversal of the rows" do
        it "yields no row once the first read every batch" do
          IOStreams.stream(db.order.in_batches(of: 2)).reader(:hash) do |reader|
            first  = reader.map { |order| order["name"] }
            second = reader.map { |order| order["name"] }

            assert_equal %w[a b c], first
            assert_empty second
          end
        end

        it "raises when the first stopped before the end, since Rails starts its batches again" do
          IOStreams.stream(db.order.in_batches(of: 2)).reader(:hash) do |reader|
            assert_equal "a", reader.first["name"]

            error = assert_raises(ArgumentError) { reader.each { |_order| flunk "read a row again" } }
            assert_equal "The rows of a query read in batches cannot be read again from where a traversal of them " \
                         "stopped, since Rails starts its batches again: read them in one traversal", error.message
          end
        end

        it "reads the batches again for a read of its own" do
          stream = IOStreams.stream(db.order.in_batches(of: 2))

          assert_equal each(stream), each(stream)
        end
      end

      describe "the order of the rows of a batch" do
        it "is the order that the database returns, for a model without a primary key, batched by a cursor:" do
          skip "cursor: needs Active Record 8.0" if ActiveRecord.version < Gem::Version.new("8.0")

          event.insert_all([{code: "b", seq: 1}, {code: "a", seq: 2}, {code: "a", seq: 1}])
          rows = nil
          sql  = batch_sql { rows = each(IOStreams.stream(event.in_batches(of: 2, cursor: %i[code seq])), :array) }

          assert_equal [%w[code seq], ["a", 1], ["a", 2], ["b", 1]], [rows.first, *rows.drop(1).sort]
          assert_equal 2, sql.size
          sql.each { |text| refute_match(/ORDER BY/i, text) }
        end

        it "is the order that the database returns, for a distinct query, which it only sorts by the columns selected" do
          rows = nil
          sql  = batch_sql { rows = each(IOStreams.stream(db.order.select(:customer_id).distinct.in_batches(of: 2))) }

          assert_equal db.order.distinct.pluck(:customer_id).sort_by(&:to_i), rows.map { |row| row["customer_id"] }.sort_by(&:to_i)
          assert_equal 2, sql.size
          sql.each { |text| refute_match(/ORDER BY/i, text) }
        end
      end

      describe "the query cache" do
        it "is left to the block as the caller set it, while the batches are read without it" do
          name     = "#{db.customer.name} Count"
          cached   = []
          callback = ->(*, payload) { cached << payload.fetch(:cached, false) if payload[:name] == name }
          # Rails finds where each batch of a query without conditions starts with ranges, otherwise by its keys.
          queries  = [db.order.in_batches(of: 2), db.order.where.not(name: "").in_batches(of: 2)]
          ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
            db.record.cache do
              queries.each { |query| IOStreams.stream(query).each(:hash) { |_order| db.customer.count } }

              assert_equal 1, db.pool.query_cache.size
            end
            IOStreams.stream(queries.first).each(:hash) { |_order| db.customer.count }
          end

          assert_equal [false, true, true, true, true, true, false, false, false], cached
        end
      end
    end
  end
end
