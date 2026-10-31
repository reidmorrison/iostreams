# frozen_string_literal: true

require_relative "query_helper"

# The stream of an Active Record query, see `IOStreams::Query::Stream`, read on each database of QueryDatabase.
class QueryStreamTest < Minitest::Test
  # The columns of the orders table, in order.
  ORDER_COLUMNS = %w[id customer_id name amount status shipped_on paid_at paid weight notes data tags secret].freeze

  # The types of field whose columns that are never null a database can always give a value, see
  # `IOStreams::Query::SqliteStatement.requirable_types`.
  REQUIRABLE_TYPES = %w[integer number boolean date datetime].freeze

  QueryDatabase.each do |database|
    describe "#{IOStreams::Query::Stream.name} on #{database.name}" do
      let(:db) { database }
      let(:orders) { db.order.order(:id) }

      include QueryTestMethods

      before { db.load }

      # Returns [Array<Hash>] the payload of each `sql.active_record` event of the supplied name within the block.
      def events(name, &)
        payloads = []
        callback = ->(_name, _start, _finish, _id, payload) { payloads << payload if payload[:name] == name }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &)
        payloads
      end

      # Returns [Class] the source that reads a query on the database, see `IOStreams::Query::SOURCES`.
      def source
        IOStreams::Query::SOURCES.map { |name| IOStreams::Query.const_get(name) }.find do |source|
          db.record.with_connection { |connection| source.reads?(connection) }
        end
      end

      # Returns [Array<Class>] the sources that define the supplied method themselves, rather than inherit it, such as
      # `IOStreams::Query::SqliteJdbc.requirable_types`, since Minitest would keep the stub of an inherited method once
      # it restores it.
      def sources_defining(name)
        IOStreams::Query::SOURCES.map { |source| IOStreams::Query.const_get(source) }.select do |source|
          source.method(name).owner == source.singleton_class
        end
      end

      # Yields while no source reads the connection, as for an adapter that cannot stream a query, such as trilogy.
      def without_sources(sources = sources_defining(:reads?), &)
        return yield if sources.empty?

        sources.first.stub(:reads?, false) { without_sources(sources.drop(1), &) }
      end

      describe "IOStreams.stream" do
        it "returns the stream of a relation, which is a stream" do
          stream = IOStreams.stream(orders)

          assert_instance_of IOStreams::Query::Stream, stream
          assert_kind_of IOStreams::Stream, stream
        end

        it "returns it for the batches of a relation" do
          assert_instance_of IOStreams::Query::Stream, IOStreams.stream(orders.in_batches(of: 2))
        end

        it "returns it for IOStreams.new too, which a copy uses" do
          assert_instance_of IOStreams::Query::Stream, IOStreams.new(orders)
        end

        it "copies the stream of a query, as it copies any stream" do
          stream = IOStreams.stream(orders.select(:id, :name)).schema(fields: [{name: "id"}, {name: "name"}])
          copy   = IOStreams.stream(stream)

          assert_instance_of IOStreams::Query::Stream, copy
          refute_same stream, copy
          assert_equal stream.schema, copy.schema
        end

        it "raises for the Enumerator that find_each returns, which cannot say how it reads its rows" do
          error = assert_raises(ArgumentError) { IOStreams.stream(orders.find_each) }
          assert_match(/`relation.in_batches\(...\)`/, error.message)
        end

        it "raises for a relation that loads associations, since its rows are not models" do
          %i[includes preload eager_load].each do |method|
            error = assert_raises(ArgumentError) { IOStreams.stream(db.order.public_send(method, :customer)) }
            assert_match(/\A#{method} cannot be read as rows/, error.message)
          end
        end

        it "raises for the batches of a grouped relation, each of which would aggregate only its own rows" do
          totals = db.order.group(:customer_id).select("customer_id, COUNT(*) AS orders")
          names  = statements do
            [totals, db.order.select("COUNT(*) AS orders").having("COUNT(*) > 1")].each do |relation|
              error = assert_raises(ArgumentError) { IOStreams.stream(relation.in_batches(of: 2)) }

              assert_equal "A grouped query cannot be read in batches, since each batch would aggregate only its own " \
                           "rows: read it as one query instead, such as with `IOStreams.stream(relation)`", error.message
            end
          end

          assert_empty names
          assert_equal 3, each(IOStreams.stream(totals)).size
        end

        it "only takes a relation" do
          assert_raises(ArgumentError) { IOStreams::Query::Stream.new([1, 2]) }
        end

        it "raises for a version of Active Record before 7.2" do
          ActiveRecord.stub(:version, Gem::Version.new("7.1.5")) do
            error = assert_raises(ArgumentError) { IOStreams.stream(orders) }
            assert_equal "IOStreams reads Active Record queries with Active Record 7.2 or later, not 7.1.5", error.message
          end
        end
      end

      describe "#each" do
        it "yields a header row of the columns, then the values of each row, as pluck returns them" do
          rows = each(IOStreams.stream(orders), :array)

          assert_equal ORDER_COLUMNS, rows.first
          assert_equal orders.pluck(*ORDER_COLUMNS), rows.drop(1)
        end

        it "yields each record by the names of its columns" do
          expected = orders.pluck(*ORDER_COLUMNS).map { |values| ORDER_COLUMNS.zip(values).to_h }

          assert_equal expected, each(IOStreams.stream(orders))
        end

        it "casts the values as the attributes of the model do" do
          first = each(IOStreams.stream(orders)).first

          assert_equal "shipped", first["status"]
          assert_equal "s1", first["secret"]
          assert_equal %w[a b], first["tags"]
          assert_equal({"x" => 1}, first["data"])
          assert_equal BigDecimal("12.5"), first["amount"]
          assert_equal Date.new(2026, 10, 1), first["shipped_on"]
          assert_instance_of ActiveSupport::TimeWithZone, first["paid_at"]
          assert_equal Time.utc(2026, 10, 2, 3, 4, 5.123456r), first["paid_at"]
        end

        it "reads the query as it is written: filtered, sorted and limited" do
          relation = db.order.where(paid: [false, nil]).order(amount: :desc).limit(2).select(:name, :amount)

          assert_equal [%w[name amount], *relation.pluck(:name, :amount)], each(IOStreams.stream(relation), :array)
        end

        it "reads a grouped query, whose computed columns take the types of the result" do
          relation = db.order.group(:status).order(:status).select("status, COUNT(*) AS orders")

          assert_equal [{"status" => "pending", "orders" => 1}, {"status" => "shipped", "orders" => 2}],
                       each(IOStreams.stream(relation))
        end

        it "reads the columns of joined tables" do
          relation = db.order.joins(:customer).order(:id).select("orders.name, customers.name AS customer")

          assert_equal [{"name" => "a", "customer" => "Acme"}, {"name" => "b", "customer" => "Globex"}],
                       each(IOStreams.stream(relation))
        end

        it "yields only the header row of a query without rows" do
          assert_equal [ORDER_COLUMNS], each(IOStreams.stream(db.order.none), :array)
          assert_empty each(IOStreams.stream(db.order.where(name: "missing")))
        end

        it "reads the rows of the batches of a relation, in those batches" do
          names = statements { assert_equal each(IOStreams.stream(orders)), each(IOStreams.stream(db.order.in_batches(of: 2))) }

          assert_equal 2, names.count("IOStreams Batch")
        end

        it "reads the rows of each batch in the order of the primary key, which Rails does not give a batch" do
          sql      = []
          callback = ->(*, payload) { sql << payload[:sql] if payload[:name] == "IOStreams Batch" }
          ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
            each(IOStreams.stream(db.order.in_batches(of: 2)))
            each(IOStreams.stream(db.order.in_batches(of: 2, use_ranges: true)))
          end

          assert_equal 4, sql.size
          unordered = sql.reject { |text| text.end_with?(%(ORDER BY "orders"."id"), "ORDER BY `orders`.`id`") }

          assert_empty unordered
        end

        it "describes the columns once for each stream, with a query of no rows" do
          stream = IOStreams.stream(orders)
          names  = statements do
            stream.infer_schema
            each(stream)
            each(stream, :array)
          end

          assert_equal 1, names.count("IOStreams Columns")
          refute_includes names, "IOStreams Batch"
        end

        it "reads the rows in slices" do
          slices = []
          IOStreams.stream(orders.select(:id, :name)).each(:slice, size: 2) { |slice| slices << slice }

          assert_equal [2, 1], slices.map(&:size)
          assert_equal %w[id name], slices.first.header
          assert_equal [{"id" => slices.last[0].first, "name" => "c"}], each(IOStreams.stream(slices.last).schema(IOStreams.stream(orders.select(:id, :name)).infer_schema))
        end

        it "reads a row whose every value is null or empty text, which is a record, not a blank line" do
          db.order.where(name: "b").update_all(name: "")
          relation = orders.select(:name, :shipped_on)
          expected = [{"name" => "a", "shipped_on" => Date.new(2026, 10, 1)}, {"name" => "", "shipped_on" => nil},
                      {"name" => "c", "shipped_on" => Date.new(1969, 12, 31)}]

          assert_equal expected, each(IOStreams.stream(relation))
          assert_equal expected, each(IOStreams.stream(relation), skip_blanks: true)
          assert_equal [%w[name shipped_on], *relation.pluck(:name, :shipped_on)], each(IOStreams.stream(relation), :array)
        end

        it "copies a row whose every value is null" do
          output = StringIO.new
          IOStreams.stream(output).format(:json).copy_from(orders.select("NULL AS a", "NULL AS b"), mode: :hash)

          assert_equal "{\"a\":null,\"b\":null}\n" * 3, output.string
        end

        it "lets the block run queries of its own" do
          counts = []
          IOStreams.stream(orders).each(:hash) { |_order| counts << db.customer.count }

          assert_equal [2, 2, 2], counts
        end

        it "checks a connection out of the pool, and checks it back in" do
          busy = []
          IOStreams.stream(orders).each(:hash) { |_order| busy << db.pool.stat[:busy] }

          assert_equal [1, 1, 1], busy
          assert_equal 0, db.pool.stat[:busy]
        end

        it "checks the connection back in when the block breaks out of the loop" do
          IOStreams.stream(orders).each(:hash) { |_order| break } # rubocop:disable Lint/UnreachableLoop -- leaves on its first row on purpose

          assert_equal 0, db.pool.stat[:busy]
          assert_equal 3, db.order.count
        end

        it "checks its connection back in when the block leases one for the thread, which is the lease of the caller" do
          leased = []
          IOStreams.stream(orders).each(:hash) { |_order| leased << db.order.lease_connection }

          assert_equal 1, leased.uniq.size
          assert_equal 1, db.pool.stat[:busy]
        ensure
          db.pool.release_connection
        end

        it "reads with an application that does not permit a connection to be held, which it hands back" do
          ActiveRecord.stub(:permanent_connection_checkout, :disallowed) do
            assert_equal 3, each(IOStreams.stream(orders)).size
            assert_equal 3, each(IOStreams.stream(orders.in_batches(of: 2))).size
          end
        end

        it "reads the rows that a query cache holds, as they are now, and adds none of them to it" do
          db.record.cache do
            each(IOStreams.stream(orders))
            db.order.update_all(name: "changed")

            assert_equal(%w[changed changed changed], each(IOStreams.stream(orders)).map { |order| order["name"] })
            assert_equal(%w[changed changed changed],
                         each(IOStreams.stream(orders.in_batches(of: 1))).map { |order| order["name"] })
            assert_equal 0, db.pool.query_cache.size
          end
        end

        it "reads the rows that were committed, on a connection of its own, not those that the caller has not committed" do
          db.record.transaction do
            db.order.create!(name: "d", amount: 1)

            assert_equal(%w[a b c], each(IOStreams.stream(orders)).map { |order| order["name"] })
            raise ActiveRecord::Rollback
          end
        end

        it "reads the rows of the connection that transactional tests pin, which the pool checks out" do
          db.pool.pin_connection!(false)
          db.order.create!(name: "d", amount: 1)

          assert_equal(%w[a b c d], each(IOStreams.stream(orders)).map { |order| order["name"] })
        ensure
          db.pool.unpin_connection!
        end
      end

      describe "the connection that a query is read on" do
        # Returns [Array] the connection of each statement that reads a query within the block.
        def read_connections(&)
          events("IOStreams Query", &).map { |payload| payload[:connection] }
        end

        it "is one of its own, so that the block runs its queries on the connection of the caller" do
          callers = []
          read    = read_connections do
            IOStreams.stream(orders).each(:hash) { |_order| callers << db.record.with_connection { |connection| connection } }
          end

          assert_equal 1, read.size
          assert_equal 1, callers.uniq.size
          refute_same read.first, callers.first
        end

        it "is that of the caller when the source says that its database cannot be read on one of its own" do
          source.stub(:own_connection?, false) do
            db.record.with_connection do |connection|
              assert_equal([connection], read_connections { each(IOStreams.stream(orders)) })
            end
          end

          assert_equal 0, db.pool.stat[:busy]
        end

        it "is that of the caller, without checking out another, when Active Record cannot use more than one" do
          db.record.with_connection do |connection|
            connection.stub(:supports_concurrent_connections?, false) do
              db.pool.stub(:checkout, ->(*) { flunk "A connection was checked out" }) do
                assert_equal([connection], read_connections { each(IOStreams.stream(orders)) })
              end
            end
          end
        end

        it "reads each row once while the block updates the rows that it reads, which moves them later in its order" do
          db.record.with_connection { |connection| connection.add_index(:orders, :amount) }
          expected = db.order.order(:amount).pluck(:id)
          ids      = []
          IOStreams.stream(db.order.order(:amount)).each(:hash) do |order|
            ids << order["id"]
            # So that a read of the same rows again, without end, fails rather than hangs.
            break if ids.size > expected.size

            db.order.find(order["id"]).update!(amount: order["amount"] + 1000)
          end

          assert_equal expected, ids
        ensure
          db.record.with_connection { |connection| connection.remove_index(:orders, :amount) }
        end

        it "reads each row once while the block inserts rows" do
          expected = orders.pluck(:id)
          ids      = []
          IOStreams.stream(orders).each(:hash) do |order|
            ids << order["id"]
            break if ids.size > expected.size

            db.order.create!(name: "new", amount: 1)
          end

          assert_equal expected, ids
        end

        it "tags a connection that cannot be checked out as Unavailable" do
          stream = IOStreams.stream(orders)
          stream.infer_schema
          error = assert_raises(ActiveRecord::ConnectionTimeoutError) do
            db.pool.stub(:checkout, ->(*) { raise ActiveRecord::ConnectionTimeoutError, "no connection free" }) do
              each(stream)
            end
          end

          assert_kind_of IOStreams::Errors::Unavailable, error
          assert_equal "#{db.order.name} query: no connection free", error.message
        end

        it "reads with a pool of one connection, which the read checks out, while the block runs no queries of its own" do
          record = Class.new(ActiveRecord::Base) { self.abstract_class = true }
          db.namespace.send(:remove_const, :SingleRecord) if db.namespace.const_defined?(:SingleRecord, false)
          db.namespace.const_set(:SingleRecord, record)
          record.establish_connection(db.record.connection_db_config.configuration_hash.merge(pool: 1, checkout_timeout: 1))
          single = Class.new(record) { self.table_name = "orders" }

          assert_equal 3, each(IOStreams.stream(single.order(:id))).size
          assert_equal 0, record.connection_pool.stat[:busy]
        ensure
          record&.connection_pool&.disconnect!
        end
      end

      describe "the SQL of a query" do
        it "is that of Active Record, with the binds that it sends, so that the rows are those that it reads" do
          [
            orders.select(:id, Arel.sql("amount * ?", 2)),
            orders.where("amount < ?", Rational(7, 2)).select(:id, :name),
            orders.where("weight >= ?", -Float::INFINITY).select(:id, :name)
          ].each do |relation|
            expected = relation.to_a.map(&:attributes)

            refute_empty expected, relation.to_sql
            assert_equal expected, each(IOStreams.stream(relation)), relation.to_sql
          end
        end

        it "is reported as Active Record reports its own statements, with its query transformers applied" do
          transformer = ->(sql, _connection) { "#{sql} /* exported */" }
          ActiveRecord.query_transformers << transformer
          relation = orders.where(paid: true)
          load     = events("#{db.order.name} Load") { relation.to_a }
          read     = events("IOStreams Query") { assert_equal 1, each(IOStreams.stream(relation)).size }

          assert_equal 1, read.size
          if QueryDatabase.jdbc?
            # AR-JDBC applies no query transformer to a statement that it runs, its own, or the cursor of PostgreSQL, while
            # a source that runs the query with its driver applies them, as Active Record defines them.
            expected = db.name == "PostgreSQL" ? load.first[:sql] : "#{load.first[:sql]} /* exported */"

            assert_operator read.first[:sql], :end_with?, expected
          else
            assert_match(%r{ /\* exported \*/\z}, read.first[:sql])
            # A source that declares a cursor for the query, such as on PostgreSQL, runs its SQL within that statement.
            assert_operator read.first[:sql], :end_with?, load.first[:sql]
          end

          assert_equal load.first[:binds], read.first[:binds]
          assert_equal type_casted_binds(load.first), type_casted_binds(read.first)
          # Active Record names a statement that it prepares, which a DECLARE never is.
          assert_empty load.first.keys - read.first.keys - [:statement_name]
        ensure
          ActiveRecord.query_transformers.delete(transformer)
        end
      end

      describe "#reader" do
        it "continues a second traversal where the first stopped, rather than running the query again" do
          names = statements do
            first, rest = IOStreams.stream(orders.select(:name)).reader(:hash) { |reader| [reader.first, reader.to_a] }

            assert_equal({"name" => "a"}, first)
            assert_equal [{"name" => "b"}, {"name" => "c"}], rest

            header, rows = IOStreams.stream(orders.select(:name)).reader(:array) { |reader| [reader.first, reader.to_a] }

            assert_equal %w[name], header
            assert_equal [%w[a], %w[b], %w[c]], rows
          end

          assert_equal 2, names.count("IOStreams Query")
        end

        it "reads the rows by the position of the fields of a schema without a header row" do
          stream = IOStreams.stream(orders.select(:id, :name))
          stream.schema(header: false, fields: [{name: "number", type: "integer"}, {name: "label"}])

          assert_equal(orders.pluck(:id, :name).map { |id, name| {"number" => id, "label" => name} }, each(stream))
          assert_equal [%w[number label], *orders.pluck(:id, :name)], each(stream, :array)
        end

        it "returns the number of rows read, header row included, as for the lines of a file of the same rows" do
          csv = StringIO.new
          IOStreams.stream(csv).format(:csv).copy_from(orders.select(:name), mode: :array)
          lines = IOStreams.stream(StringIO.new(csv.string)).format(:csv).each(:hash) { |_record| nil }

          assert_equal 4, lines
          assert_equal lines, IOStreams.stream(orders.select(:name)).each(:hash) { |_order| nil }
          assert_equal lines, IOStreams.stream(orders.select(:name)).each(:array) { |_row| nil }
          assert_equal lines, IOStreams.stream(db.order.select(:id, :name).in_batches(of: 2)).each(:hash) { |_order| nil }
          assert_equal lines, IOStreams.stream(StringIO.new).format(:csv).copy_from(orders.select(:name), mode: :hash)
        end
      end

      describe "#infer_schema" do
        # Yields while every source says that a column that is never null always has a value once cast, when it is of
        # one of the types, see `IOStreams::Query::SqliteStatement.requirable_types`.
        def with_requirable_types(types, sources = sources_defining(:requirable_types), &)
          return yield if sources.empty?

          sources.first.stub(:requirable_types, types) { with_requirable_types(types, sources.drop(1), &) }
        end

        it "describes the columns of the query as the fields of a schema" do
          expected = {
            fields: [
              {name: "id", type: "integer", constraints: {required: true}},
              {name: "customer_id", type: "integer"},
              {name: "name", type: "string"},
              {name: "amount", type: "number", decimals: 2, constraints: {required: true}},
              {name: "status", type: "string"},
              {name: "shipped_on", type: "date"},
              {name: "paid_at", type: "datetime"},
              {name: "paid", type: "boolean"},
              {name: "weight", type: "number", floatNumber: true},
              {name: "notes", type: "string"},
              {name: "data", type: "any"},
              {name: "tags", type: "any"},
              {name: "secret", type: "string"}
            ]
          }

          with_requirable_types(REQUIRABLE_TYPES) { assert_equal expected, IOStreams.stream(orders).infer_schema.to_h }
        end

        it "is frozen" do
          assert_predicate IOStreams.stream(orders).infer_schema, :frozen?
        end

        it "requires the columns of the table that are never null, when the query only selects columns of the table" do
          required = lambda do |relation|
            IOStreams.stream(relation).infer_schema.to_h[:fields].select { |field| field[:constraints] }.map { |field| field[:name] }
          end

          with_requirable_types(REQUIRABLE_TYPES) do
            assert_equal %w[id amount], required.call(db.order.select(:id, "amount", :name))
            assert_equal %w[amount], required.call(db.order.select(db.order.arel_table[:amount]))
            assert_equal %w[id amount], required.call(db.order.where(paid: true).order(:id).group(:id, :amount).select(:id, :amount))
          end
          with_requirable_types(%w[number]) { assert_equal %w[amount], required.call(db.order.select(:id, :amount)) }
        end

        it "requires no column of a query that computes a column, or joins another table, which can be null" do
          [
            db.order.select("id, amount"),
            db.order.select(:id, "NULLIF(amount, 0) AS amount"),
            db.order.joins(:customer).select(:id, :amount),
            db.order.left_joins(:customer).select(:id, :amount),
            db.order.from("orders").select(:id, :amount),
            db.order.group(Arel.sql("id, amount")).select(:id, :amount),
            db.order.with(paid_orders: db.order.where(paid: true)).select(:id, :amount)
          ].each do |relation|
            fields = with_requirable_types(REQUIRABLE_TYPES) { IOStreams.stream(relation).infer_schema.to_h[:fields] }

            assert_equal [], fields.select { |field| field[:constraints] }, relation.to_sql
          end
        end

        it "returns the schema that was set instead" do
          schema = {fields: [{name: "id", type: "integer"}, {name: "data", type: "object"}]}
          stream = IOStreams.stream(orders.select(:id, :data).limit(1)).schema(schema)

          assert_equal schema, stream.schema
          assert_equal IOStreams::Schema.new(schema), stream.infer_schema
        end

        it "leaves #schema to return only the schema that was set, nil without one, as for a path" do
          stream = IOStreams.stream(orders.select(:id))

          assert_nil stream.schema
          assert_equal([{name: "id", type: "integer"}], stream.infer_schema.to_h[:fields].map { |field| field.except(:constraints) })
          assert_nil stream.schema
        end

        it "reads the rows through a contract, whose aliases match the columns, with every field in its order" do
          contract = IOStreams::Contract.new(
            fieldsMatch: "partial",
            fields:      [
              {name: "total", type: "number", decimals: 2, aliases: ["amount"]},
              {name: "label", type: "string", aliases: ["name"]},
              {name: "missing", type: "integer"}
            ]
          )
          records = each(IOStreams.stream(orders.select(:id, :name, :amount)).as(contract))

          assert_equal [{"total" => BigDecimal("12.5"), "label" => "a", "missing" => nil},
                        {"total" => BigDecimal("3"), "label" => "b", "missing" => nil},
                        {"total" => BigDecimal("100.25"), "label" => "c", "missing" => nil}], records
          assert(records.all? { |record| record["total"].is_a?(BigDecimal) })
        end

        it "copies the records of a contract to a target without a schema, rather than by the columns of the query" do
          contract = IOStreams::Contract.new(
            fieldsMatch: "partial",
            fields:      [{name: "total", type: "number", decimals: 2, aliases: ["amount"]}, {name: "label", aliases: ["name"]}]
          )
          output = StringIO.new
          IOStreams.stream(output).format(:csv).copy_from(IOStreams.stream(orders.select(:id, :name, :amount)).as(contract), mode: :hash)

          assert_equal "total,label\n12.5,a\n3.0,b\n100.25,c\n", output.string
        end

        it "raises before the first row for a required field of a contract that the query has no column for" do
          contract = IOStreams::Contract.new(fieldsMatch: "partial", fields: [{name: "zip", constraints: {required: true}}])

          assert_raises(IOStreams::Errors::InvalidHeader) { each(IOStreams.stream(orders.select(:id)).as(contract)) }
        end

        it "reads the rows by the schema that was set" do
          stream = IOStreams.stream(orders.select(:id, :name, :data))
          stream.schema(fieldsMatch: "partial", fields: [{name: "label", aliases: ["name"]}, {name: "data", type: "any"}])

          assert_equal [{"label" => "a", "data" => {"x" => 1}}, {"label" => "b", "data" => [1, 2]},
                        {"label" => "c", "data" => nil}], each(stream)
        end

        it "raises for a value that the schema that was set does not accept" do
          stream = IOStreams.stream(orders.select(:data)).schema(fields: [{name: "data", type: "object"}])

          assert_raises(IOStreams::Errors::InvalidValue) { each(stream) }
        end

        it "raises for two columns of the same name, which a record cannot hold" do
          relation = db.order.joins(:customer).select("orders.name, customers.name")
          error    = assert_raises(ArgumentError) { IOStreams.stream(relation).infer_schema }

          assert_equal "The query has more than one column named \"name\": give each column a name of its own, such " \
                       "as with `AS`", error.message
        end
      end

      describe "#copy_from" do
        let(:relation) { orders.select(:id, :name, :amount, :status, :shipped_on, :paid_at, :paid, :notes, :data) }

        # Yields a local file that holds "existing\n", whose contents a copy that fails must keep.
        def existing_file
          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "orders.csv")
            path.write("existing\n")
            yield path

            assert_equal "existing\n", path.read
          end
        end

        it "opens the query before the target, so that a query that no source can stream keeps the target" do
          existing_file do |path|
            without_sources { assert_raises(ArgumentError) { path.copy_from(orders, mode: :hash) } }
          end
        end

        it "opens the query before the target, so that a query that fails at its first row keeps the target" do
          existing_file do |path|
            relation = orders.select(Arel.sql("abs(-9223372036854775807 - 1) AS overflow"))
            error    = assert_raises(StandardError) { path.copy_from(relation, mode: :hash) }

            assert_match(/overflow|out of range/, error.message)
          end
        end

        it "writes CSV by the schema of the columns" do
          output = StringIO.new
          IOStreams.stream(output).format(:csv).copy_from(relation, mode: :hash)

          assert_equal <<~CSV, output.string
            id,name,amount,status,shipped_on,paid_at,paid,notes,data
            #{relation.first.id},a,12.50,shipped,2026-10-01,2026-10-01T23:04:05.123456-04:00,true,"first, ""quoted""","{""x"":1}"
            #{relation.second.id},b,3.00,pending,,,false,,"[1,2]"
            #{relation.third.id},c,100.25,shipped,1969-12-31,,,,
          CSV
        end

        it "writes JSON by the schema of the columns, in the :array mode too" do
          output = StringIO.new
          IOStreams.stream(output).format(:json).copy_from(relation.where(name: "a"), mode: :array)

          assert_equal "{\"id\":#{relation.first.id},\"name\":\"a\",\"amount\":12.50,\"status\":\"shipped\"," \
                       "\"shipped_on\":\"2026-10-01\",\"paid_at\":\"2026-10-01T23:04:05.123456-04:00\",\"paid\":true," \
                       "\"notes\":\"first, \\\"quoted\\\"\",\"data\":{\"x\":1}}\n", output.string
        end

        it "writes the batches of a relation" do
          output = StringIO.new
          IOStreams.stream(output).format(:csv).copy_from(db.order.select(:id, :name).in_batches(of: 2), mode: :array)

          assert_equal "id,name\n#{orders.pluck(:id, :name).map { |values| values.join(',') }.join("\n")}\n", output.string
        end

        it "writes by the schema of the target instead, when it has one, which is not changed" do
          output = StringIO.new
          target = IOStreams.stream(output).format(:csv).schema(fieldsMatch: "partial", fields: [{name: "name"}])
          target.copy_from(relation, mode: :hash)

          assert_equal "name\na\nb\nc\n", output.string
          assert_equal({fieldsMatch: "partial", fields: [{name: "name"}]}, target.schema)
        end

        it "does not set the schema of the target" do
          target = IOStreams.stream(StringIO.new).format(:csv)
          target.copy_from(relation, mode: :hash)

          assert_nil target.schema
        end

        it "writes Parquet, which keeps the types of the columns" do
          skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "orders.parquet")
            path.copy_from(orders.select(:name, :amount, :shipped_on, :paid_at, :paid, :weight), mode: :hash)
            records = []
            path.schema(IOStreams.stream(orders.select(:name, :amount, :shipped_on, :paid_at, :paid, :weight)).infer_schema)
            path.each(:hash) { |record| records << record }

            assert_equal(%w[a b c], records.map { |record| record["name"] })
            assert_equal([BigDecimal("12.5"), BigDecimal(3), BigDecimal("100.25")], records.map { |record| record["amount"] })
            assert_equal([Date.new(2026, 10, 1), nil, Date.new(1969, 12, 31)], records.map { |record| record["shipped_on"] })
            assert_equal Time.utc(2026, 10, 2, 3, 4, 5.123456r), records.first["paid_at"]
            assert_in_delta 1.5, records.first["weight"]
          end
        end

        it "raises for Parquet before it writes the file, for a column that has no Parquet type" do
          skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

          Dir.mktmpdir do |dir|
            path  = IOStreams.path(dir, "orders.parquet")
            error = assert_raises(ArgumentError) { path.copy_from(orders.select(:name, :data), mode: :hash) }

            assert_match(/\AField "data": a field of type "any" has no Parquet type/, error.message)
            refute_predicate path, :exist?
          end
        end

        it "raises for the :line mode before it runs a query" do
          names = statements do
            assert_raises(ArgumentError) { IOStreams.stream(StringIO.new).copy_from(orders, mode: :line) }
          end

          assert_empty names
        end

        it "raises without a mode, since a query holds rows rather than bytes" do
          error = assert_raises(ArgumentError) { IOStreams.stream(StringIO.new).copy_from(orders) }

          assert_equal "A query is read in the :array, :hash or :slice mode, not :stream, since it holds rows rather " \
                       "than bytes or lines", error.message
        end
      end

      describe "a query is only read" do
        let(:stream) { IOStreams.stream(orders) }

        it "has the :array format, which cannot be changed" do
          assert_equal :array, stream.format
          assert_equal :array, stream.format(:array).format
          error = assert_raises(ArgumentError) { stream.format(:csv) }

          assert_equal "The rows of the query are :array, so its format cannot be :csv", error.message
        end

        it "cannot be read as :text, since its rows are values rather than text" do
          error = assert_raises(ArgumentError) { stream.format(:text) }

          assert_equal "The rows of the query are :array, so its format cannot be :text", error.message
        end

        it "raises for the modes of bytes and lines" do
          assert_raises(ArgumentError) { stream.each(:line) { |_line| nil } }
          assert_raises(ArgumentError) { stream.reader { |_io| nil } }
          assert_raises(ArgumentError) { stream.read }
        end

        it "raises for writing" do
          error = assert_raises(ArgumentError) { stream.writer(:hash) { |_io| nil } }

          assert_equal "A query is only read: write its rows or records to a path or stream, such as with " \
                       "`copy_to(path, mode: :hash)`", error.message
          assert_raises(ArgumentError) { stream.write("a") }
          assert_raises(ArgumentError) { stream.copy_from(StringIO.new("a,b\n"), mode: :line) }
        end

        it "raises for streams, options and encodings" do
          error = assert_raises(ArgumentError) { stream.stream(:gz) }

          assert_equal "The streams and options of #stream and #option cannot be used with a query, which holds rows " \
                       "rather than bytes", error.message
          assert_raises(ArgumentError) { stream.option(:pgp, passphrase: "secret") }
          assert_raises(ArgumentError) { stream.option(:parquet, compression: "zstd") }
          assert_raises(ArgumentError) { stream.encoding("BINARY") }
          assert_raises(ArgumentError) { stream.raw }
          assert_raises(ArgumentError) { stream.remove_from_pipeline(:gz) }
          assert_nil stream.encoding
        end

        it "raises for a file name, which has no effect on a query, whose rows are always :array" do
          error = assert_raises(ArgumentError) { stream.file_name("orders.csv") }

          assert_equal "A query has no file name, since its rows are always in the :array format: name the file that " \
                       "its rows are copied to instead, such as with `copy_to(\"orders.csv\", mode: :hash)`", error.message
          assert_raises(ArgumentError) { stream.file_name = "orders.json" }
          assert_raises(ArgumentError) { stream.file_name(nil) }
          assert_nil stream.file_name
          assert_equal :array, stream.format
        end

        it "raises for blank_rows:, which the stream supplies, rather than a call" do
          error = assert_raises(ArgumentError) { each(stream, :hash, blank_rows: true) }

          assert_match(/\AUnknown option :blank_rows for the :hash mode/, error.message)
        end

        it "raises for the options of lines" do
          error = assert_raises(ArgumentError) { each(stream, :hash, delimiter: "|") }

          assert_equal "delimiter: cannot be used to read a query, whose rows are already split", error.message
        end

        it "raises for the options of lines before it runs a query, even while the database cannot be reached" do
          names = statements do
            db.order.stub(:with_connection, ->(**) { raise ActiveRecord::ConnectionNotEstablished, "connection refused" }) do
              assert_raises(ArgumentError) { each(stream, :array, buffer_size: 10) }
              assert_raises(ArgumentError) { each(stream, :hash, embedded_within: '"') }
              assert_raises(ArgumentError) { stream.each(:slice, size: 2, delimiter: "|") { |_slice| nil } }
            end
          end

          assert_empty names
        end

        it "can be copied to a path or stream" do
          output = StringIO.new
          IOStreams.stream(orders.select(:name)).copy_to(IOStreams.stream(output).format(:csv), mode: :array)

          assert_equal "name\na\nb\nc\n", output.string
        end
      end

      describe "#inspect" do
        it "names the model and the batches" do
          assert_equal "#<IOStreams::Query::Stream #{db.order.name} query>", IOStreams.stream(orders).inspect
          assert_equal "#<IOStreams::Query::Stream #{db.order.name} query in batches of 2>",
                       IOStreams.stream(orders.in_batches(of: 2)).inspect
        end
      end

      describe "failures" do
        it "tags a failure of the database with the kind of failure, and the name of the query" do
          error = assert_raises(ActiveRecord::ConnectionNotEstablished) do
            db.order.stub(:with_connection, ->(**) { raise ActiveRecord::ConnectionNotEstablished, "connection refused" }) do
              each(IOStreams.stream(orders))
            end
          end

          assert_kind_of IOStreams::Errors::Unavailable, error
          assert_equal "#{db.order.name} query", error.display_name
          assert_equal "#{db.order.name} query: connection refused", error.message
        end

        it "does not tag what the block raises, which is not a failure of the query" do
          error = assert_raises(ActiveRecord::ConnectionNotEstablished) do
            IOStreams.stream(orders).each(:hash) do |_order| # rubocop:disable Lint/UnreachableLoop -- raises on its first row on purpose
              raise ActiveRecord::ConnectionNotEstablished, "of the block"
            end
          end

          refute_kind_of IOStreams::Errors::StorageError, error
        end

        it "raises when the columns of the query change after it is described" do
          stream = IOStreams.stream(db.order.order(:id))
          stream.infer_schema
          db.record.with_connection { |connection| connection.add_column(:orders, :extra, :string) }
          begin
            error = assert_raises(IOStreams::Errors::InvalidHeader) { each(stream) }

            if [IOStreams::Query::MysqlJdbc, IOStreams::Query::SqliteJdbc].include?(source)
              # Whose driver yields the values of each row without the names of the columns.
              assert_match(/\AThe columns of the query changed after it was described, from \d+ columns to \d+\z/, error.message)
            else
              assert_match(/\AThe columns of the query changed after it was described, from \[.*"secret"\] to \[.*"secret", "extra"\]\z/,
                           error.message)
            end
          ensure
            db.record.with_connection { |connection| connection.remove_column(:orders, :extra) }
            db.order.reset_column_information
          end
        end

        it "raises for an adapter that cannot stream a query, suggesting batches" do
          without_sources do
            error = assert_raises(ArgumentError) { each(IOStreams.stream(orders)) }

            assert_equal "IOStreams cannot stream a query on #{db.record.with_connection(&:adapter_name)}, so read it in " \
                         "batches, such as with `IOStreams.stream(relation.in_batches(of: 10_000))`", error.message
            assert_equal 3, each(IOStreams.stream(orders.in_batches(of: 2))).size
          end
        end
      end
    end
  end

  describe IOStreams::Query::Columns do
    # Returns [Array<String>] the types of the fields of the schema of columns of the supplied types, each never null,
    # that are required, on a database that always gives a value to a column of the requirable types that is never null.
    def required(*types, requirable_types: REQUIRABLE_TYPES)
      columns = IOStreams::Query::Columns.new(names: types.each_index.map { |index| "c#{index}" }, types: types,
                                              not_null: [true] * types.size, requirable_types: requirable_types)
      columns.schema[:fields].select { |field| field[:constraints] }.map { |field| field[:type] }
    end

    it "requires a column that is never null, of a type that the database always gives a value" do
      types = [ActiveModel::Type::Integer.new, ActiveModel::Type::Decimal.new(scale: 2), ActiveModel::Type::Float.new,
               ActiveModel::Type::Boolean.new, ActiveModel::Type::Date.new, ActiveModel::Type::DateTime.new]

      assert_equal %w[integer number number boolean date datetime], required(*types)
      assert_equal %w[integer date], required(*types, requirable_types: %w[integer date])
      assert_empty required(*types, requirable_types: [])
    end

    it "does not require a column whose values can be empty, such as text, binary or JSON, whatever the database" do
      assert_empty required(ActiveModel::Type::String.new, ActiveModel::Type::Binary.new, ActiveRecord::Type::Json.new,
                            ActiveModel::Type::Value.new, requirable_types: REQUIRABLE_TYPES + %w[string any])
    end

    it "raises for two columns of the same name" do
      error = assert_raises(ArgumentError) do
        IOStreams::Query::Columns.new(names: %w[id id], types: [ActiveModel::Type::Integer.new] * 2, not_null: [false] * 2,
                                      requirable_types: [])
      end

      assert_match(/more than one column named "id"/, error.message)
    end
  end

  describe IOStreams::Query::Failure do
    # Returns the kind of failure of the exception, and the exceptions of a driver that it asked the block about.
    def kind(exception)
      asked = []
      kind  = IOStreams::Query::Failure.kind(exception) { |driver_exception| asked << driver_exception and nil }
      [kind, asked]
    end

    it "tags what means that the database cannot be reached, or could not answer, as Unavailable" do
      [
        ActiveRecord::ConnectionNotEstablished.new("refused"),
        ActiveRecord::ConnectionTimeoutError.new("no connection free"),
        ActiveRecord::ConnectionFailed.new("lost"),
        ActiveRecord::QueryCanceled.new("canceled"),
        ActiveRecord::StatementTimeout.new("timeout"),
        ActiveRecord::AdapterTimeout.new("timeout"),
        ActiveRecord::LockWaitTimeout.new("lock"),
        ActiveRecord::Deadlocked.new("deadlock"),
        ActiveRecord::SerializationFailure.new("serialization")
      ].each do |exception|
        assert_equal [IOStreams::Errors::Unavailable, []], kind(exception), exception.class.name
      end
    end

    it "tags credentials that the database rejects as PermissionDenied" do
      assert_equal [IOStreams::Errors::PermissionDenied, []], kind(ActiveRecord::DatabaseConnectionError.username_error("jack"))
    end

    # Returns the exception, raised with the supplied cause.
    def caused(exception, cause)
      begin
        raise cause
      rescue cause.class
        raise exception
      end
    rescue exception.class => e
      e
    end

    it "asks the sources about the exception of the driver that caused a connection that could not be made" do
      cause = Errno::ECONNREFUSED.new

      [
        ActiveRecord::ConnectionNotEstablished.new("refused"),
        ActiveRecord::DatabaseConnectionError.hostname_error("db.example.org"),
        ActiveRecord::DatabaseConnectionError.username_error("jack")
      ].each do |exception|
        asked = []
        IOStreams::Query::Failure.kind(caused(exception, cause)) { |driver_exception| asked << driver_exception and nil }

        assert_equal [cause], asked, exception.class.name
      end

      denied = IOStreams::Query::Failure.kind(caused(ActiveRecord::DatabaseConnectionError.hostname_error("db"), cause)) do
        IOStreams::Errors::PermissionDenied
      end

      assert_equal IOStreams::Errors::PermissionDenied, denied
    end

    it "tags a connection that the driver says nothing of as Unavailable, unless it names the host, which may not resolve" do
      cause = Errno::ECONNREFUSED.new

      assert_equal [IOStreams::Errors::Unavailable, [cause]], kind(caused(ActiveRecord::ConnectionNotEstablished.new("refused"), cause))
      assert_equal [nil, [cause]], kind(caused(ActiveRecord::DatabaseConnectionError.hostname_error("nowhere"), cause))
      assert_equal [IOStreams::Errors::PermissionDenied, [cause]],
                   kind(caused(ActiveRecord::DatabaseConnectionError.username_error("jack"), cause))
      assert_equal [nil, []], kind(ActiveRecord::DatabaseConnectionError.hostname_error("nowhere"))
    end

    it "does not tag a role or shard without a database, whatever caused it" do
      no_pool = ActiveRecord::ConnectionNotEstablished.new("No connection pool for 'ActiveRecord::Base' found.")

      assert_equal [nil, []], kind(caused(no_pool, Errno::ECONNREFUSED.new))
      if defined?(ActiveRecord::ConnectionNotDefined)
        assert_equal [nil, []], kind(caused(ActiveRecord::ConnectionNotDefined.new("no role"), Errno::ECONNREFUSED.new))
      end

      assert_equal [nil, []], kind(ActiveRecord::RecordNotFound.new("missing"))
    end

    it "asks the sources about the exception of the driver that caused any other StatementInvalid" do
      cause = RuntimeError.new("permission denied for table orders")

      assert_equal [nil, [cause]], kind(caused(ActiveRecord::StatementInvalid.new("PG::InsufficientPrivilege"), cause))
      assert_equal [nil, [cause]], kind(caused(ActiveRecord::NoDatabaseError.new("no database"), cause))
      assert_equal [nil, []], kind(ActiveRecord::StatementInvalid.new("syntax error"))
    end

    it "asks the sources about an exception that the driver raised itself" do
      exception = RuntimeError.new("other")

      assert_equal [nil, [exception]], kind(exception)
    end

    it "does not tag an exception that the source of its driver knows to be none of the kinds, whatever Active Record " \
       "names it" do
      cause = RuntimeError.new("could not translate host name \"jack-db.invalid\" to address: Name or service not known")
      none  = IOStreams::Query::Failure::NONE

      [
        ActiveRecord::ConnectionNotEstablished.new("could not translate host name"),
        ActiveRecord::DatabaseConnectionError.username_error("jack"),
        ActiveRecord::DatabaseConnectionError.hostname_error("jack-db.invalid"),
        ActiveRecord::NoDatabaseError.new("no database"),
        ActiveRecord::StatementInvalid.new("invalid")
      ].each do |exception|
        assert_nil IOStreams::Query::Failure.kind(caused(exception, cause)) { none }, exception.class.name
      end

      assert_nil IOStreams::Query::Failure.kind(cause) { none }
    end
  end
end
