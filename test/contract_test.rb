# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "json"

class ContractTest < Minitest::Test
  class Order < IOStreams::Contract
    fields_match "partial"

    field :id,         :integer, required: true
    field :amount,     :number,  decimals: 2
    field :ordered_at, :datetime, name: "Ordered At", aliases: ["created_at"]
    field :zip,        :string
  end

  describe IOStreams::Contract do
    describe ".new" do
      it "returns a new contract class whose fields are a Frictionless Table Schema, as Struct.new returns a class" do
        contract = IOStreams::Contract.new("fields" => [{"name" => "id", "type" => "integer"}], "fieldsMatch" => "subset")

        assert_kind_of Class, contract
        assert_operator contract, :<, IOStreams::Contract
        assert_equal({fieldsMatch: "subset", fields: [{name: "id", type: "integer"}]}, contract.to_h)
        assert_equal ["id"], contract.fields.map(&:name)
        assert_instance_of IOStreams::Schema, contract.schema
      end

      it "takes the properties as keywords too" do
        assert_equal [{name: "id", type: "integer"}], IOStreams::Contract.new(fields: [{name: "id", type: "integer"}]).to_h[:fields]
      end

      it "takes a schema" do
        schema = IOStreams::Schema.new(fields: [{name: "id", type: "integer"}])

        assert_equal schema, IOStreams::Contract.new(schema).schema
      end

      it "evaluates a block in the new class, as Struct.new does" do
        contract = IOStreams::Contract.new(fields: [{name: "id"}]) do
          def self.label = "orders"
        end

        assert_equal "orders", contract.label
      end

      it "returns a new class each time" do
        refute_same IOStreams::Contract.new(fields: []), IOStreams::Contract.new(fields: [])
      end

      it "raises for a schema that is not valid" do
        assert_raises(ArgumentError) { IOStreams::Contract.new(fields: [{name: "id", type: "year"}]) }
        assert_raises(ArgumentError) { IOStreams::Contract.new([{name: "id"}]) }
        assert_raises(ArgumentError) { IOStreams::Contract.new({fields: []}, fieldsMatch: "subset") }
      end

      it "raises for the properties that lay out a file, which a contract never does" do
        [
          {fields: [{name: "id", width: 10}]},
          {fields: [{name: "id", start: 2}]},
          {fields: [{name: "id", type: "string", truncate: true}]},
          {fields: [{name: "id", skip: true}]},
          {fields: [{name: "id"}], header: false},
          {fields: [{name: "id"}], width: 80}
        ].each do |descriptor|
          error = assert_raises(ArgumentError) { IOStreams::Contract.new(descriptor) }

          assert_includes error.message, "A contract never lays out a file", descriptor.inspect
        end
      end

      it "accepts how a file writes its text, which a contract alone can read by" do
        contract = IOStreams::Contract.new(fields: [{name: "on", type: "date", format: "%m/%d/%Y"},
                                                    {name: "ok", type: "boolean", trueValues: ["Y"], falseValues: ["N"]}])

        assert_equal "%m/%d/%Y", contract.to_h[:fields].first[:format]
      end
    end

    describe "a subclass" do
      it "declares its fields, in order, by the names of their accessors, with the name of each in its schema" do
        assert_equal(
          {
            fieldsMatch: "partial",
            fields:      [
              {name: "id", type: "integer", constraints: {required: true}},
              {name: "amount", type: "number", decimals: 2},
              {name: "Ordered At", type: "datetime", aliases: ["created_at"]},
              {name: "zip", type: "string"}
            ]
          },
          Order.to_h
        )
      end

      it "names the properties of a field as Ruby does" do
        contract = Class.new(IOStreams::Contract) do
          field :paid, :boolean, true_values: ["Y"], false_values: ["N"]
          field :ratio, :number, float_number: true
          field :note, :string, required: true, allow_blank: true
          key_type "symbol"
        end

        assert_equal(
          {keyType: "symbol",
           fields:  [{name: "paid", type: "boolean", trueValues: ["Y"], falseValues: ["N"]},
                     {name: "ratio", type: "number", floatNumber: true},
                     {name: "note", type: "string", allowBlank: true, constraints: {required: true}}]},
          contract.to_h
        )
      end

      it "defaults the type to any" do
        assert_equal "any", Class.new(IOStreams::Contract) { field :data }.fields.first.type
      end

      it "starts a subclass of a contract with its fields" do
        wide = Class.new(Order) { field :notes, :string }

        assert_equal ["id", "amount", "Ordered At", "zip", "notes"], wide.fields.map(&:name)
        assert_equal ["id", "amount", "Ordered At", "zip"], Order.fields.map(&:name)
      end

      it "raises for a field that is not valid as it is declared" do
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :id, :year } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field "id", :integer } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :"my-field", :integer } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :id, :integer, colour: "red" } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { fields_match "loose" } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :id, required: "no" } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :id, type: :integer } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { fields_match nil } }
      end

      it "keeps the other constraints of a required field, named as Ruby names them, which a field rejects unless supported" do
        error = assert_raises(ArgumentError) do
          Class.new(IOStreams::Contract) { field :id, :integer, required: true, constraints: {max_length: 5} }
        end

        assert_includes error.message, '"maxLength" is not supported'
      end

      it "names the subclass that has no fields" do
        error = assert_raises(ArgumentError) { Class.new(IOStreams::Contract).schema }

        assert_includes error.message, "has no fields: declare them with field"
      end

      it "raises for a field that lays out a file" do
        error = assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :id, :string, width: 10 } }

        assert_includes error.message, 'width of the field "id"'
      end

      it "shows its name, or its schema when it has none" do
        hash = {fields: [{name: "id"}]}

        assert_equal "ContractTest::Order", Order.inspect
        assert_equal "#<IOStreams::Contract #{hash.inspect}>", IOStreams::Contract.new(hash).inspect
      end
    end

    describe ".to_dsl" do
      it "writes the Ruby of a class that declares the contract, which builds the same contract" do
        assert_equal(<<~RUBY, Order.to_dsl("Order"))
          class Order < IOStreams::Contract
            fields_match "partial"

            field :id,         :integer,  required: true
            field :amount,     :number,   decimals: 2
            field :ordered_at, :datetime, aliases: ["created_at"], name: "Ordered At"
            field :zip,        :string
          end
        RUBY
        copy = Class.new(IOStreams::Contract) { class_eval(Order.to_dsl("Copy").lines[1..-2].join, __FILE__, __LINE__) }

        assert_equal Order.to_h, copy.to_h
      end

      it "names a field of a contract built from a Hash as Ruby can, keeping its name, and comments other properties" do
        contract = IOStreams::Contract.new(
          title:  "Orders",
          fields: [{name: "Ordered At", type: "datetime"}, {name: "1st"}, {name: "Ordered-At"}, {name: :zip},
                   {name: "paid", type: "boolean", trueValues: ["Y"], constraints: {required: true}}]
        )

        assert_equal(<<~RUBY, contract.to_dsl)
          class Contract < IOStreams::Contract
            # title: "Orders"

            field :ordered_at,   :datetime, name: "Ordered At"
            field :field_1st,    :any,      name: "1st"
            field :ordered_at_2, :any,      name: "Ordered-At"
            field :zip,          :any,      name: :zip
            field :paid,         :boolean,  required: true, true_values: ["Y"]
          end
        RUBY
      end

      it "keeps the name of a field that is a Ruby name as its accessor, numbering a cleansed name that is the same" do
        contract = IOStreams::Contract.new(fields: [{name: "Ordered At"}, {name: "ordered_at"}, {name: "Ordered-At"}])

        assert_equal %i[ordered_at_2 ordered_at ordered_at_3], contract.accessors # rubocop:disable Naming/VariableNumber
      end

      it "writes no blank line for a contract without fields" do
        assert_equal "class Empty < IOStreams::Contract\n  fields_match \"subset\"\nend\n",
                     IOStreams::Contract.new(fieldsMatch: "subset", fields: []).to_dsl("Empty")
      end
    end

    describe "IOStreams::Contract itself" do
      it "has no fields" do
        assert_raises(ArgumentError) { IOStreams::Contract.schema }
        assert_raises(ArgumentError) { IOStreams::Contract.field(:id, :integer) }
        assert_raises(ArgumentError) { IOStreams::Contract.fields_match("subset") }
      end
    end

    describe "IOStreams::Schema#to_contract" do
      it "drops what lays out a file, the fields that only hold the place of a column, and the format of the text" do
        schema = IOStreams::Schema.new(
          header:      false,
          width:       40,
          fieldsMatch: "exact",
          fields:      [
            {name: "id", type: "integer", width: 10, constraints: {required: true}},
            {name: "filler", width: 2, skip: true},
            {name: "on", type: "date", width: 8, format: "%Y%m%d", start: 13},
            {name: "name", type: "string", width: 20, truncate: true}
          ]
        )

        assert_equal(
          {fieldsMatch: "exact",
           fields:      [{name: "id", type: "integer", constraints: {required: true}}, {name: "on", type: "date"},
                         {name: "name", type: "string"}]},
          schema.to_contract.to_h
        )
      end
    end
  end
end
