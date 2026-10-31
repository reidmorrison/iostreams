# frozen_string_literal: true

require_relative "test_helper"
require "json"

class AsTest < Minitest::Test
  class Order < IOStreams::Contract
    fields_match "partial"

    field :id,         :integer, required: true
    field :amount,     :number,  decimals: 2
    field :ordered_at, :datetime, aliases: ["created_at", "Order Date"]
    field :zip,        :string
  end

  describe IOStreams::Stream do
    describe "#as" do
      let(:order) do
        {"id" => 1001, "amount" => BigDecimal("12.5"), "ordered_at" => Time.utc(2026, 10, 25, 9, 30), "zip" => "01234"}
      end

      # Returns [IOStreams::Stream] a stream of the text, read as the file name says.
      def text(text, file_name = "orders.csv")
        IOStreams.stream(StringIO.new(text)).file_name(file_name)
      end

      # Returns [Array] the rows or records read from the stream.
      def read(stream, mode = :hash)
        rows = []
        stream.each(mode) { |row| rows << row }
        rows
      end

      # Returns [String] what the stream writes for the records.
      def write(records, file_name: "orders.csv", contract: Order, schema: nil, mode: :hash)
        out = StringIO.new
        IOStreams.stream(out).file_name(file_name).schema(schema).as(contract).writer(mode) do |io|
          records.each { |record| io << record }
        end
        out.string
      end

      it "returns the stream, so that it chains" do
        stream = text("id\n1\n")

        assert_same stream, stream.as(Order)
      end

      it "reads every source as the same records: the keys of the contract, in its order, with values of its types" do
        csv  = "ID,Zip,Amount,Ordered At,Notes\n1001,01234,12.50,2026-10-25T09:30:00Z,hi\n"
        json = %({"zip":"01234","created_at":"2026-10-25T09:30:00Z","amount":12.50,"id":1001,"notes":"hi"}\n)

        assert_equal [order], read(text(csv).as(Order))
        assert_equal [order], read(text(json, "orders.json").as(Order))
        assert_equal order.keys, read(text(csv).as(Order)).first.keys
      end

      it "reads JSON numbers of a number field exactly, rather than through a Float" do
        record = read(text(%({"id":1,"amount":0.1000000000000000055511151231257827}\n), "orders.json").as(Order)).first

        assert_equal BigDecimal("0.1000000000000000055511151231257827"), record["amount"]
      end

      it "gives every record every field of the contract, nil for a column that the source does not have" do
        assert_equal [{"id" => 1, "amount" => nil, "ordered_at" => nil, "zip" => nil}], read(text("id,notes\n1,a\n").as(Order))
      end

      it "reads a key that a JSON record leaves out as a missing value, nil, as an empty CSV value is" do
        exact = IOStreams::Contract.new(fields: [{name: "id", type: "integer"}, {name: "zip", type: "string"}])

        assert_equal [{"id" => 1, "zip" => nil}], read(text(%({"id":1}\n), "orders.json").as(exact))
        assert_equal [{"id" => 1, "zip" => nil}], read(text("id,zip\n1,\n").as(exact))
      end

      it "raises InvalidValue for a key of a required field that a JSON record leaves out, naming the record" do
        error = assert_raises(IOStreams::Errors::InvalidValue) { read(text(%({"id":1}\n{"amount":2}\n), "orders.json").as(Order)) }

        assert_equal 'Field "id" is required, but has no value, in record 2 on line 2', error.message
      end

      it "raises for a key of a required field that a JSON record leaves out, read as rows, or hands the row on" do
        json = text(%({"zip":"1"}\n{"id":2}\n), "orders.json").as(Order)
        assert_raises(IOStreams::Errors::InvalidValue) { read(json, :array) }

        problems = []
        rows     = []
        text(%({"zip":"1"}\n{"id":2}\n), "orders.json").as(Order).each(:array, on_invalid: ->(row) { problems << row }) do |row|
          rows << row
        end

        assert_equal [1], problems.map(&:record_number)
        assert_equal [%w[id amount ordered_at zip], [2, nil, nil, nil]], rows
      end

      it "reads a key that a JSON record leaves out of a required field that allows blank values as nil" do
        blank = IOStreams::Contract.new(fields: [{name: "id", type: "integer"}, {name: "zip", constraints: {required: true}, allowBlank: true}])

        assert_equal [{"id" => 1, "zip" => nil}], read(text(%({"id":1}\n), "orders.json").as(blank))
      end

      it "keeps the rule of fieldsMatch for each JSON record read by a schema of the file" do
        schema = {fields: [{name: "id", type: "integer"}, {name: "zip", type: "string"}]}

        assert_raises(IOStreams::Errors::InvalidHeader) { read(text(%({"id":1}\n), "orders.json").schema(schema).as(Order)) }
      end

      it "still raises for a key of a JSON record that an exact contract does not have" do
        exact = IOStreams::Contract.new(fields: [{name: "id", type: "integer"}])

        assert_raises(IOStreams::Errors::InvalidHeader) { read(text(%({"id":1,"notes":"x"}\n), "orders.json").as(exact)) }
      end

      it "yields the keys of the contract as the header row of each(:array), and the values of every field in order" do
        rows = read(text("Zip,ID\n01234,1\n").as(Order), :array)

        assert_instance_of IOStreams::Row::HeaderRow, rows.first
        assert_equal [%w[id amount ordered_at zip], [1, nil, nil, "01234"]], rows
      end

      it "raises before the first row for a required column that the source does not have" do
        stream = text("amount\n12.5\n").as(Order)
        rows   = []

        error = assert_raises(IOStreams::Errors::InvalidHeader) { stream.each(:hash) { |row| rows << row } }
        assert_includes error.message, 'missing the required field "id"'
        assert_empty rows
      end

      it "raises for a value that is not of the type of its field" do
        error = assert_raises(IOStreams::Errors::InvalidValue) { read(text("id,amount\n1,N/A\n").as(Order)) }

        assert_includes error.message, 'Field "amount"'
      end

      it "takes the Hash of a contract, which it builds" do
        stream = text("ID,Name\n1,Jack\n").as(fieldsMatch: "subset", fields: [{name: "id", type: "integer"}])

        assert_equal [{"id" => 1}], read(stream)
      end

      it "takes a schema, which it makes a contract" do
        schema = IOStreams::Schema.new(fieldsMatch: "subset", fields: [{name: "id", type: "integer"}])

        assert_equal [{"id" => 1}], read(text("ID,Name\n1,Jack\n").as(schema))
      end

      it "removes the contract with nil" do
        assert_equal [{"id" => "1", "name" => "Jack"}], read(text("ID,Name\n1,Jack\n").as(Order).as(nil))
      end

      it "raises for anything else, such as a record of a contract, IOStreams::Contract itself, or the path of a file" do
        [Order.new(id: 1), IOStreams::Contract, String, "orders.json", [{name: "id"}]].each do |contract|
          assert_raises(ArgumentError, contract.inspect) { text("id\n1\n").as(contract) }
        end
      end

      it "raises for the Hash of a contract that lays out a file" do
        assert_raises(ArgumentError) { text("id\n1\n").as(fields: [{name: "id", width: 3}]) }
      end

      it "raises FrozenError for a frozen stream" do
        assert_raises(FrozenError) { text("id\n1\n").freeze.as(Order) }
      end

      it "raises for a contract supplied to a call, which is set on the path" do
        error = assert_raises(ArgumentError) { text("id\n1\n").each(:hash, contract: Order) { nil } }

        assert_includes error.message, "path.as(Order)"
      end

      it "converts nothing in the :line mode, which reads the lines as they are stored" do
        assert_equal ["id,amount", "1,12.50"], read(text("id,amount\n1,12.50\n").as(Order), :line)
      end

      it "raises for a fixed width file without a schema, which a contract never lays out" do
        error = assert_raises(ArgumentError) { read(text("0001\n", "orders.fixed").as(Order)) }

        assert_includes error.message, "needs a schema"
      end

      it "writes the records by the fields of the contract, naming and ordering the columns, and converting each value" do
        csv = write([{"zip" => "01234", "id" => "1001", "ordered_at" => order["ordered_at"], "amount" => 12.5}])

        assert_equal "id,amount,ordered_at,zip\n1001,12.50,2026-10-25T09:30:00Z,01234\n", csv
      end

      it "writes JSON by the fields of the contract" do
        json = write([order], file_name: "orders.json")

        assert_equal %({"id":1001,"amount":12.50,"ordered_at":"2026-10-25T09:30:00Z","zip":"01234"}\n), json
      end

      it "raises for a value written that is not of the type of its field" do
        assert_raises(IOStreams::Errors::InvalidValue) { write([{"id" => "x"}]) }
      end

      it "copies a file into a target with a contract, which writes by it" do
        out = StringIO.new
        IOStreams.stream(out).file_name("orders.csv").as(Order).copy_from(text("Zip,ID,Notes\n01234,1001,a\n"), mode: :hash)

        assert_equal "id,amount,ordered_at,zip\n1001,,,01234\n", out.string
      end

      describe "Parquet" do
        before do
          skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)
        end

        it "passes each value of the type of its field through, and converts the others" do
          Dir.mktmpdir do |dir|
            path   = IOStreams.path(dir, "orders.parquet")
            schema = {
              fields: [
                {name: "id", type: "string"},
                {name: "amount", type: "number", decimals: 2},
                {name: "created_at", type: "datetime"},
                {name: "zip", type: "string"},
                {name: "notes", type: "string"}
              ]
            }
            path.schema(schema).writer(:hash) do |io|
              io << {"id" => "1001", "amount" => BigDecimal("12.5"), "created_at" => order["ordered_at"], "zip" => "01234"}
            end

            assert_equal [order], read(IOStreams.path(dir, "orders.parquet").as(Order))
          end
        end

        it "writes the types of the fields of the contract" do
          Dir.mktmpdir do |dir|
            IOStreams.path(dir, "orders.parquet").as(Order).writer(:hash) { |io| io << order }

            assert_equal [{name: "id", type: "integer", constraints: {required: true}},
                          {name: "amount", type: "number", decimals: 2},
                          {name: "ordered_at", type: "datetime"},
                          {name: "zip", type: "string"}], IOStreams.path(dir, "orders.parquet").infer_schema.to_h[:fields]
            assert_equal [order], read(IOStreams.path(dir, "orders.parquet").as(Order))
          end
        end
      end

      describe "with a schema of the file, which lays it out" do
        let(:layout) do
          {
            fields: [
              {name: "ID", type: "integer", width: 10},
              {name: "Amount", type: "number", width: 10, decimals: 2},
              {name: "Order Date", type: "datetime", width: 14, format: "%Y%m%d%H%M%S"},
              {name: "Filler", width: 1, skip: true},
              {name: "Zip", type: "string", width: 5}
            ]
          }
        end

        let(:line) { "00000010010000012.5020261025093000 01234" }

        it "reads the file by the schema, and the records by the contract, which meets the fields by their names" do
          assert_equal [order], read(text("#{line}\n", "orders.fixed").schema(layout).as(Order))
          assert_equal [%w[id amount ordered_at zip], order.values],
                       read(text("#{line}\n", "orders.fixed").schema(layout).as(Order), :array)
        end

        it "writes the records by the contract, and the file by the schema" do
          assert_equal "#{line}\n", write([order], file_name: "orders.fixed", schema: layout)
        end

        it "raises before the first row for a required field of the contract that the schema does not have" do
          schema = {fields: [{name: "Amount", type: "number", width: 10}]}

          error = assert_raises(IOStreams::Errors::InvalidHeader) { read(text("0000012.50\n", "orders.fixed").schema(schema).as(Order)) }
          assert_includes error.message, 'missing the required field "id"'
        end

        it "raises before the first row for a required field of the contract whose column the file does not have" do
          schema = {fieldsMatch: "partial", fields: [{name: "ID", type: "integer"}, {name: "Amount", type: "number"}]}

          %W[Amount\n2\n Amount\n].each do |csv|
            error = assert_raises(IOStreams::Errors::InvalidHeader) { read(text(csv, "orders.csv").schema(schema).as(Order)) }
            assert_includes error.message, 'missing the required field "id"'
          end
        end

        it "infers the schema of the file, rather than the contract" do
          assert_equal(%w[id name], text("ID,Name\n1,x\n", "orders.csv").as(Order).infer_schema.fields.map(&:name))
        end
      end
    end
  end
end
