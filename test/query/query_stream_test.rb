# frozen_string_literal: true

require_relative "query_helper"

# The stream of an Active Record query, see `IOStreams::Query::Stream`, read on each database of QueryDatabase.
class QueryStreamTest < Minitest::Test
  # The columns of the orders table, in order.
  ORDER_COLUMNS = %w[id customer_id name amount status shipped_on paid_at paid weight notes data tags secret].freeze

  QueryDatabase.each do |database|
    describe "#{IOStreams::Query::Stream.name} on #{database.name}" do
      let(:db) { database }
      let(:orders) { db.order.order(:id) }

      before { db.load }

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

      # Yields while no source reads the connection, as for an adapter that cannot stream a query, such as trilogy.
      def without_sources(sources = IOStreams::Query::SOURCES.map { |name| IOStreams::Query.const_get(name) }, &)
        return yield if sources.empty?

        sources.first.stub(:reads?, false) { without_sources(sources.drop(1), &) }
      end

      describe "IOStreams.stream" do
        it "returns the stream of a relation, which is a stream" do
          stream = IOStreams.stream(orders)

          assert_instance_of IOStreams::Query::Stream, stream
          assert_kind_of IOStreams::Stream, stream
          assert_instance_of IOStreams::Query, stream.io_stream
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

        it "reads a relation with one query, and its columns with another of no rows" do
          names = statements { each(IOStreams.stream(orders)) }

          assert_equal ["IOStreams Columns"], names
        end

        it "describes the columns once for each stream" do
          stream = IOStreams.stream(orders)
          names  = statements do
            stream.schema
            each(stream)
            each(stream, :array)
          end

          assert_equal ["IOStreams Columns"], names
        end

        it "reads the rows in slices" do
          slices = []
          IOStreams.stream(orders.select(:id, :name)).each(:slice, size: 2) { |slice| slices << slice }

          assert_equal [2, 1], slices.map(&:size)
          assert_equal %w[id name], slices.first.header
          assert_equal [{"id" => slices.last.first.first, "name" => "c"}], each(IOStreams.stream(slices.last).schema(IOStreams.stream(orders.select(:id, :name)).schema))
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

        it "borrows a connection, and hands it back to the pool" do
          busy = []
          IOStreams.stream(orders).each(:hash) { |_order| busy << db.pool.stat[:busy] }

          assert_equal [1, 1, 1], busy
          assert_equal 0, db.pool.stat[:busy]
        end

        it "hands the connection back when the block breaks out of the loop" do
          IOStreams.stream(orders).each(:hash) { |_order| break } # rubocop:disable Lint/UnreachableLoop -- leaves on its first row on purpose

          assert_equal 0, db.pool.stat[:busy]
          assert_equal 3, db.order.count
        end

        it "hands the connection back when the block leases it for the thread" do
          IOStreams.stream(orders).each(:hash) { |_order| db.order.lease_connection }

          assert_equal 0, db.pool.stat[:busy]
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

        it "reads the rows of a transaction that the caller has not committed" do
          db.record.transaction do
            db.order.create!(name: "d", amount: 1)

            assert_equal 4, each(IOStreams.stream(orders)).size
            raise ActiveRecord::Rollback
          end
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
      end

      describe "#reader" do
        it "continues a second traversal where the first stopped, rather than running the query again" do
          first, rest = IOStreams.stream(orders.select(:name)).reader(:hash) { |reader| [reader.first, reader.to_a] }

          assert_equal({"name" => "a"}, first)
          assert_equal [{"name" => "b"}, {"name" => "c"}], rest

          header, rows = IOStreams.stream(orders.select(:name)).reader(:array) { |reader| [reader.first, reader.to_a] }

          assert_equal %w[name], header
          assert_equal [%w[a], %w[b], %w[c]], rows
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

      describe "#schema" do
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

          assert_equal expected, IOStreams.stream(orders).schema
        end

        it "is frozen" do
          assert_predicate IOStreams.stream(orders).schema, :frozen?
        end

        it "requires the columns of the table that are never null, when the query only selects columns of the table" do
          required = lambda do |relation|
            IOStreams.stream(relation).schema[:fields].select { |field| field[:constraints] }.map { |field| field[:name] }
          end

          assert_equal %w[id amount], required.call(db.order.select(:id, "amount", :name))
          assert_equal %w[amount], required.call(db.order.select(db.order.arel_table[:amount]))
          assert_equal %w[id amount], required.call(db.order.where(paid: true).order(:id).group(:id, :amount).select(:id, :amount))
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
            fields = IOStreams.stream(relation).schema[:fields]

            assert_equal [], fields.select { |field| field[:constraints] }, relation.to_sql
          end
        end

        it "returns the schema that was set instead" do
          schema = {fields: [{name: "id", type: "integer"}, {name: "data", type: "object"}]}

          assert_equal schema, IOStreams.stream(orders.select(:id, :data).limit(1)).schema(schema).schema
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
          error    = assert_raises(ArgumentError) { IOStreams.stream(relation).schema }

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
            path.schema(IOStreams.stream(orders.select(:name, :amount, :shipped_on, :paid_at, :paid, :weight)).schema)
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

        it "writes the columns that the copy supplies, rather than the schema of the query" do
          output = StringIO.new
          target = IOStreams.stream(output).format(:csv)
          assert_deprecated(/columns: is deprecated/) do
            target.copy_from(orders.select(:name, :amount), mode: :hash, columns: %w[amount name])
          end

          assert_equal "amount,name\n12.5,a\n3.0,b\n100.25,c\n", output.string
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
          stream.schema
          db.record.with_connection { |connection| connection.add_column(:orders, :extra, :string) }
          begin
            error = assert_raises(IOStreams::Errors::InvalidHeader) { each(stream) }

            assert_match(/\AThe columns of the query changed after it was described, from \[.*"secret"\] to \[.*"secret", "extra"\]\z/,
                         error.message)
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
    # Returns [Array<String>] the names of the fields of the schema of columns of the supplied types, each never null,
    # that are required.
    def required(*types)
      columns = IOStreams::Query::Columns.new(names: types.each_index.map { |index| "c#{index}" }, types: types,
                                              not_null: [true] * types.size)
      columns.schema[:fields].select { |field| field[:constraints] }.map { |field| field[:type] }
    end

    it "requires a column that is never null, when its values cannot be empty" do
      assert_equal %w[integer number number boolean date datetime],
                   required(ActiveModel::Type::Integer.new, ActiveModel::Type::Decimal.new(scale: 2),
                            ActiveModel::Type::Float.new, ActiveModel::Type::Boolean.new, ActiveModel::Type::Date.new,
                            ActiveModel::Type::DateTime.new)
    end

    it "does not require a column whose values can be empty, such as text, binary or JSON" do
      assert_empty required(ActiveModel::Type::String.new, ActiveModel::Type::Binary.new, ActiveRecord::Type::Json.new,
                            ActiveModel::Type::Value.new)
    end

    it "raises for two columns of the same name" do
      error = assert_raises(ArgumentError) do
        IOStreams::Query::Columns.new(names: %w[id id], types: [ActiveModel::Type::Integer.new] * 2, not_null: [false] * 2)
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
  end
end
