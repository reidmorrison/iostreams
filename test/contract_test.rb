# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"

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
        assert_raises(ArgumentError) { IOStreams::Contract.new(fields: [{name: "id", type: "geojson"}]) }
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
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :id, :geojson } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field "id", :integer } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :"my-field", :integer } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :id, :integer, colour: "red" } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { fields_match "loose" } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :id, required: "no" } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :id, type: :integer } }
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { fields_match nil } }
      end

      it "sets the missing values of every field with missing_values, which a field's own missing_values: replaces" do
        contract = Class.new(IOStreams::Contract) do
          missing_values ["", "NA"]
          field :id, :integer
          field :score, :integer, missing_values: ["-99"]
        end

        assert_equal({missingValues: ["", "NA"], fields: [{name: "id", type: "integer"}, {name: "score", type: "integer", missingValues: ["-99"]}]},
                     contract.to_h)
        assert_nil contract.new(id: "NA").id
        assert_nil contract.new(score: "-99").score
        assert_raises(IOStreams::Errors::InvalidValue) { contract.new(score: "NA") }
        assert_includes contract.to_dsl("Scores"), %(  missing_values ["", "NA"]\n)
        assert_includes contract.to_dsl("Scores"), %(field :score, :integer, missing_values: ["-99"])
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { missing_values "NA" } }
      end

      it "checks the other constraints of a field, and its categories, and writes them as Ruby names them" do
        contract = Class.new(IOStreams::Contract) do
          field :code, :string, constraints: {min_length: 2, pattern: "[A-Z]+"}, categories: %w[AB CD], categories_ordered: true
          field :age, :integer, required: true, constraints: {minimum: 0, exclusive_maximum: 150}
        end

        assert_equal({minLength: 2, pattern: "[A-Z]+"}, contract.fields.first.to_h[:constraints])
        assert_equal "AB", contract.new(code: "AB", age: 3).code
        assert_raises(IOStreams::Errors::InvalidValue) { contract.new(code: "EF", age: 3) }
        assert_raises(IOStreams::Errors::InvalidValue) { contract.new(code: "AB", age: 150) }
        dsl = contract.to_dsl("Codes")

        assert_includes dsl, %(constraints: {min_length: 2, pattern: "[A-Z]+"})
        assert_includes dsl, %(required: true, constraints: {minimum: 0, exclusive_maximum: 150})
        assert_equal contract.to_h, Class.new(IOStreams::Contract) { class_eval(dsl.lines[1..-2].join, __FILE__, __LINE__) }.to_h
      end

      it "raises for an option of a field that is not a property of a field, which a schema from a Hash would keep" do
        error = assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { field :weight, :number, unit: "kg" } }
        assert_equal 'The field "weight" has no option :unit, which is not a property of a field, see IOStreams::Schema::Field',
                     error.message
        assert_equal({name: "weight", type: "number", unit: "kg"},
                     IOStreams::Contract.new(fields: [{name: "weight", type: "number", unit: "kg"}]).fields.first.to_h)
      end

      it "keeps the other constraints of a required field, named as Ruby names them, which a field rejects unless supported" do
        error = assert_raises(ArgumentError) do
          Class.new(IOStreams::Contract) { field :id, :integer, required: true, constraints: {json_schema: {}} }
        end

        assert_includes error.message, '"jsonSchema" is not supported'
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

      it "holds its schema frozen, without freezing the Hashes, Arrays and Strings that it was built from" do
        descriptor = JSON.parse(<<~JSON)
          {"fieldsMatch": "subset", "fields": [
            {"name": "id", "type": "integer", "constraints": {"enum": [1, 2]}},
            {"name": "code", "type": "string", "constraints": {"pattern": "[A-Z]+"}},
            {"name": "at", "type": "datetime", "format": "%Y-%m-%d %H:%M", "timeZone": "America/New_York"},
            {"name": "tags", "type": "list", "itemType": "string"}
          ]}
        JSON
        contract = IOStreams::Contract.new(descriptor)
        # The values within the descriptor, since Ruby freezes each String key of a Hash itself.
        texts    = []
        walk     = lambda do |value|
          texts << value if value.is_a?(String) || value.is_a?(Hash) || value.is_a?(Array)
          value.each { |item| walk.call(item) } if value.is_a?(Array)
          value.each_value { |item| walk.call(item) } if value.is_a?(Hash)
        end
        walk.call(descriptor)

        assert_equal [], texts.select(&:frozen?)
        assert_predicate contract.schema.fields.first.type, :frozen?
        assert_predicate contract.record_fields, :frozen?
        descriptor["fields"].first["type"].upcase!

        assert_equal "integer", contract.schema.fields.first.type
        # A copy, which the caller can change.
        assert_equal 5, (contract.to_h[:fields] << {name: "more"}).size
      end

      it "holds its schema and the field of each accessor in a form that every Ractor can read" do
        skip("#{RUBY_ENGINE} has no Ractors") unless defined?(Ractor)

        assert Ractor.shareable?(Order.schema)
        assert Ractor.shareable?(Order.record_fields)
        assert Ractor.shareable?(Class.new(Order) { field :note }.record_fields)
      end

      it "reads and writes its records in a Ractor, through an alias of an accessor, and in a subclass" do
        skip("#{RUBY_ENGINE} has no Ractors") unless defined?(Ractor)

        script = <<~RUBY
          require "iostreams"
          Warning[:experimental] = false
          class Order < IOStreams::Contract
            field :id, :integer
            alias_method :identifier, :id
            alias_method :identifier=, :id=
          end
          class Note < Order
            field :text, :string
          end
          # Loads what the records use in the main Ractor, which Ruby 3.3 cannot load from another.
          Note.new(id: 1, text: "a").identifier = 2
          ractor = Ractor.new do
            note            = Note.new(id: "1", text: 2)
            note.identifier = "7"
            [note.id, note.identifier, note.text, note.to_h]
          end
          p(ractor.respond_to?(:value) ? ractor.value : ractor.take)
        RUBY
        out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)

        assert_predicate status, :success?, err
        assert_equal [7, 7, "2", {"id" => 7, "text" => "2"}].inspect, out.chomp
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
