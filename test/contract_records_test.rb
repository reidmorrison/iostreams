# frozen_string_literal: true

require_relative "test_helper"

class ContractRecordsTest < Minitest::Test
  class Order < IOStreams::Contract
    fields_match "partial"

    field :id,         :integer, required: true
    field :amount,     :number,  decimals: 2
    field :ordered_at, :datetime, name: "Ordered At", aliases: ["created_at"]
    field :zip,        :string
  end

  describe IOStreams::Contract do
    let(:at) { Time.utc(2026, 10, 25, 9, 30) }

    describe "a record" do
      it "takes the value of each field by its name in Ruby, converting and checking it as it is set" do
        order = Order.new(id: "1001", amount: 12.5, ordered_at: "2026-10-25T09:30:00Z", zip: 1234)

        assert_equal 1001, order.id
        assert_equal BigDecimal("12.5"), order.amount
        assert_equal at, order.ordered_at
        assert_equal "1234", order.zip
      end

      it "takes the value of a field by its name in the schema too" do
        assert_equal at, Order.new(id: 1, "Ordered At" => at).ordered_at
      end

      it "is nil for a field without a value" do
        assert_nil Order.new(id: 1).zip
      end

      it "raises where it is made for a bad value, or no value for a required field" do
        assert_raises(IOStreams::Errors::InvalidValue) { Order.new(id: "x") }
        assert_raises(IOStreams::Errors::InvalidValue) { Order.new(amount: 1) }
      end

      it "raises for a field that the contract does not have" do
        error = assert_raises(ArgumentError) { Order.new(id: 1, colour: "red") }

        assert_includes error.message, ":colour"
      end

      it "converts and checks a value that is set" do
        order     = Order.new(id: 1)
        order.zip = 1234

        assert_equal "1234", order.zip
        assert_raises(IOStreams::Errors::InvalidValue) { order.amount = "N/A" }
      end

      it "reads a value by its name in Ruby or in the schema" do
        order = Order.new(id: 1, ordered_at: at)

        assert_equal at, order[:ordered_at]
        assert_equal at, order["Ordered At"]
        assert_raises(ArgumentError) { order[:colour] }
      end

      it "returns its values by the names of the fields in the schema, in order" do
        assert_equal({"id" => 1, "amount" => nil, "Ordered At" => at, "zip" => nil}, Order.new(ordered_at: at, id: 1).to_h)
      end

      it "equals a record of the same contract with the same values" do
        assert_equal Order.new(id: 1), Order.new(id: "1")
        assert_equal Order.new(id: 1).hash, Order.new(id: "1").hash
        refute_equal Order.new(id: 1), Order.new(id: 2)
        refute_equal Order.new(id: 1), Class.new(Order).new(id: 1)
      end

      it "shows the value of each field by its name in Ruby" do
        assert_equal '#<ContractRecordsTest::Order id=1, amount=nil, ordered_at=nil, zip="0">', Order.new(id: 1, zip: "0").inspect
      end

      it "names the fields of a contract built from a Hash as Ruby can" do
        contract = IOStreams::Contract.new(fields: [{name: "Ordered At", type: "datetime"}, {name: "hash"}, {name: "1st"}])
        record   = contract.new(ordered_at: at, hash_field: 1, field_1st: 2)

        assert_equal [at, 1, 2], [record.ordered_at, record.hash_field, record.field_1st]
        assert_equal %i[ordered_at hash_field field_1st], contract.accessors
      end

      it "inherits the fields of a contract that it subclasses" do
        wide = Class.new(Order) { field :notes, :string }

        assert_equal "hi", wide.new(id: 1, notes: "hi").notes
      end

      it "gives a subclass the accessors of the fields that it inherits, and the methods that its contract defines" do
        base = Class.new(IOStreams::Contract) do
          field :placed_at, :datetime, name: "Placed"
          field :amount, :number

          def amount = "custom"
        end
        copy  = Class.new(base)
        order = copy.new(placed_at: at, amount: 1)
        order.placed_at = "2026-10-25T09:30:00Z"

        assert_equal %i[placed_at amount], copy.record_fields.keys
        assert_equal [at, "custom"], [order.placed_at, order.amount]
        refute copy.method_defined?(:placed)
      end

      it "names a field as a function of Kernel, such as format or select, which a record never calls on itself" do
        contract = Class.new(IOStreams::Contract) do
          field :format, :string
          field :select
        end

        assert_equal %w[mp4 x], [contract.new(format: "mp4").format, contract.new(select: "x").select]
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :raise } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :initialize_copy } }
      end

      it "raises for a field whose accessor a field that it inherits already has, also one that its name gives it" do
        base = IOStreams::Contract.new(fields: [{name: "Ordered At"}])

        assert_raises(ArgumentError) { Class.new(base) { field :ordered_at, :string, name: "Placed" } }
      end

      it "keeps the accessors of a contract whose field is not valid, so that it can be declared again" do
        contract = Class.new(IOStreams::Contract) { field :id }
        assert_raises(ArgumentError) { contract.field(:amount, :money) }
        contract.field(:amount, :number)

        assert_equal %i[id amount], contract.accessors
      end

      it "is eql? to a record of values that are eql?, as a Hash key needs" do
        contract = IOStreams::Contract.new(fields: [{name: "v"}])

        assert_equal contract.new(v: 1), contract.new(v: 1.0)
        refute contract.new(v: 1).eql?(contract.new(v: 1.0))
        assert_equal 1, {contract.new(v: 1) => 1}[contract.new(v: 1)]
      end

      it "takes a String as a name in the schema, and a Symbol as a name in Ruby, and raises for two keys of one field" do
        contract = Class.new(IOStreams::Contract) do
          field :a, name: "b"
          field :b, name: "a"
        end
        record = contract.new(a: 1, b: 2)

        assert_equal [2, 1], [record["a"], record[:a]]
        assert_equal record, contract.new(**record.to_h)
        assert_raises(ArgumentError) { Order.new(id: 1, "id" => 2) }
      end

      it "raises for a field named as a method that every record answers, or as another field" do
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :hash } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :to_h } }
        assert_raises(ArgumentError) do
          Class.new(IOStreams::Contract) do
            field :id
            field :id, :integer, name: "ID"
          end
        end
      end
    end
  end

  describe IOStreams::Stream do
    # Returns [IOStreams::Stream] a stream of the text, read as the file name says.
    def text(text, file_name = "orders.csv")
      IOStreams.stream(StringIO.new(text)).file_name(file_name)
    end

    describe "each(:record)" do
      it "yields each record read through the contract as a record of its class" do
        records = []
        text("ID,Amount,Ordered At,Zip\n1001,12.50,2026-10-25T09:30:00Z,01234\n").as(Order).each(:record) do |order|
          records << order
        end

        assert_equal [Order.new(id: 1001, amount: BigDecimal("12.5"), ordered_at: "2026-10-25T09:30:00Z", zip: "01234")], records
        assert_instance_of Order, records.first
      end

      it "yields nil for a blank row, as each(:hash) does, unless skip_blanks skips it" do
        rows = []
        text("ID\n1\n\n2\n").as(Order).each(:record) { |order| rows << order&.id }

        assert_equal [1, nil, 2], rows
        assert_equal 2, text("ID\n1\n\n2\n").as(Order).reader(:record, skip_blanks: true, &:count)
      end

      it "raises before the file is opened without a contract" do
        error = assert_raises(ArgumentError) { IOStreams.path("/does/not/exist.csv").each(:record) { nil } }

        assert_includes error.message, "#as"
      end

      it "resumes at a record number that a slice holds" do
        slices = []
        text("ID\n1\n2\n3\n4\n").each(:slice, size: 2) { |slice| slices << slice }
        ids = []
        IOStreams.stream(slices.last).as(Order).each(:record, resume_at: 4) { |order| ids << order.id }

        assert_equal [4], ids
      end

      it "raises for an option that it does not take, naming the mode" do
        error = assert_raises(ArgumentError) { text("ID\n1\n").as(Order).each(:record, columns: ["id"]) { nil } }

        assert_includes error.message, "for the :record mode"
      end
    end

    describe "writer(:record)" do
      it "writes the records of the contract, each column headed by the name of its field" do
        out = StringIO.new
        IOStreams.stream(out).file_name("orders.csv").as(Order).writer(:record) do |io|
          io << Order.new(id: 1001, amount: BigDecimal("12.5"), ordered_at: Time.utc(2026, 10, 25, 9, 30), zip: "01234")
        end

        assert_equal "id,amount,Ordered At,zip\n1001,12.50,2026-10-25T09:30:00Z,01234\n", out.string
      end

      it "raises for anything but a record of the contract, such as a record of a subclass, which has other fields" do
        assert_raises(ArgumentError) do
          IOStreams.stream(StringIO.new).file_name("orders.csv").as(Order).writer(:record) { |io| io << {"id" => 1} }
        end
        wide = Class.new(Order) { field :notes, :string }
        assert_raises(ArgumentError) do
          IOStreams.stream(StringIO.new).file_name("orders.csv").as(Order).writer(:record) { |io| io << wide.new(id: 1) }
        end
      end

      it "writes the records of the contract to a store of slices" do
        store = Class.new do
          include IOStreams::Slice::Target

          attr_reader :slices

          def write_slice(slice)
            (@slices ||= []) << slice
          end
        end.new
        IOStreams.stream(store).format(:csv).as(Order).writer(:record) { |io| io << Order.new(id: 1001, zip: "01234") }
        records = []
        IOStreams.stream(store.slices.first).as(Order).each(:record) { |order| records << order }

        assert_equal [Order.new(id: 1001, zip: "01234")], records
      end

      it "raises before the file is opened without a contract" do
        Dir.mktmpdir do |dir|
          assert_raises(ArgumentError) { IOStreams.path(dir, "orders.csv").writer(:record) { nil } }
          refute_path_exists File.join(dir, "orders.csv")
        end
      end
    end
  end
end
