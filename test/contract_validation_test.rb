# frozen_string_literal: true

require_relative "test_helper"

class ContractValidationTest < Minitest::Test
  class Order < IOStreams::Contract
    fields_match "partial"

    field :id,         :integer, required: true
    field :amount,     :number,  decimals: 2
    field :ordered_at, :datetime, aliases: ["created_at"]
  end

  describe IOStreams::Stream do
    # Returns [IOStreams::Stream] a stream of the text, read as the file name says, through the contract.
    def upload(text, file_name = "orders.csv", contract: Order)
      IOStreams.stream(StringIO.new(text)).file_name(file_name).as(contract)
    end

    describe "#validate_contract!" do
      it "returns true for a source that meets the contract" do
        assert upload("ID,Amount\n1,12.50\n").validate_contract!
      end

      it "checks the columns, not the values, so that it reads no row" do
        assert upload("ID,Amount\n1,N/A\n").validate_contract!
      end

      it "raises as reading would for a column that the contract requires" do
        error   = assert_raises(IOStreams::Errors::InvalidHeader) { upload("Amount,Notes\n12.5,x\n").validate_contract! }
        reading = assert_raises(IOStreams::Errors::InvalidHeader) { upload("Amount,Notes\n12.5,x\n").each(:hash) { nil } }

        assert_equal reading.message, error.message
        assert_includes error.message, 'missing the required field "id"'
      end

      it "checks the keys of the first record of JSON, a key that it leaves out being a missing value, not a column" do
        exact = IOStreams::Contract.new(fields: [{name: "id", type: "integer", constraints: {required: true}}])

        assert upload(%({"id":1}\n), "orders.json").validate_contract!
        assert upload(%({"amount":1}\n), "orders.json").validate_contract!
        assert_raises(IOStreams::Errors::InvalidHeader) { upload(%({"id":1,"notes":"x"}\n), "orders.json", contract: exact).validate_contract! }
      end

      it "checks the header row against a schema of the file first, as reading does" do
        schema = {fields: [{name: "id", type: "integer"}, {name: "amount", type: "number"}]}
        error   = assert_raises(IOStreams::Errors::InvalidHeader) { upload("Zip\n1\n").schema(schema).validate_contract! }
        reading = assert_raises(IOStreams::Errors::InvalidHeader) { upload("Zip\n1\n").schema(schema).each(:hash) { nil } }
        assert_equal reading.message, error.message
        assert_equal 2, upload("Zip\n1\n").schema(schema).contract_errors.size
        assert upload("ID,Amount\n1,2\n").schema(schema).validate_contract!
      end

      it "returns an IO that it reads to where it was, so that its rows are still read" do
        source = upload("ID,Amount\n1,12.50\n")
        source.validate_contract!
        source.contract_errors
        records = []
        source.each(:hash) { |record| records << record }

        assert_equal([1], records.map { |record| record["id"] })
      end

      it "raises for an empty source, which has no columns, while reading it yields no records" do
        assert_raises(IOStreams::Errors::InvalidHeader) { upload("").validate_contract! }
        assert_equal 0, upload("").each(:hash) { nil }
      end

      it "raises when no contract is set" do
        error = assert_raises(ArgumentError) { IOStreams.stream(StringIO.new("id\n1\n")).validate_contract! }

        assert_includes error.message, "#as"
      end
    end

    describe "#contract_valid?" do
      it "answers whether the source meets the contract" do
        assert_predicate upload("ID\n1\n"), :contract_valid?
        refute_predicate upload("Amount\n1\n"), :contract_valid?
      end
    end

    describe "#contract_errors" do
      let(:exact) do
        IOStreams::Contract.new(fields: [{name: "id", type: "integer"}, {name: "amount", type: "number"}])
      end

      it "returns [] for a source that meets the contract" do
        assert_equal [], upload("ID,Amount\n1,12.50\n").contract_errors
      end

      it "lists every problem of the columns at once, each as an InvalidHeader, not raised" do
        errors = upload("Notes,Zip\nx,y\n", contract: exact).contract_errors

        assert(errors.all?(IOStreams::Errors::InvalidHeader))
        assert_equal 2, errors.size
        assert_includes errors.first.message, 'the columns "Notes" and "Zip" are not fields of the schema'
        assert_includes errors.last.message, 'missing the fields "id" and "amount"'
      end

      it "lists a header row whose columns are in another order than an exact contract" do
        errors = upload("Amount,ID\n1,2\n", contract: exact).contract_errors

        assert_equal 1, errors.size
        assert_includes errors.first.message, "not in the order of the fields"
      end

      it "lists two columns that the contract keeps, which are the same key" do
        contract = IOStreams::Contract.new(extraColumns: "keep", keyType: "cleansed", fieldsMatch: "partial", fields: [{name: "id"}])
        source   = upload("id,Notes,notes\n1,2,3\n", contract: contract)

        assert_raises(IOStreams::Errors::InvalidHeader) { source.validate_contract! }
        assert_equal [IOStreams::Errors::InvalidHeader], source.contract_errors.map(&:class)
      end

      it "lists two columns that are the same field" do
        errors = upload("ID,id\n1,2\n").contract_errors

        assert_equal 1, errors.size
        assert_includes errors.first.message, '"ID" and "id" are both the field "id"'
      end
    end

    describe "a column whose declared type never fits its field" do
      it "raises IncompatibleType, which is not an InvalidHeader, as the schema of the file declares it" do
        schema = {fields: [{name: "id", type: "integer", width: 4}, {name: "amount", type: "boolean", width: 1}]}
        stream = IOStreams.stream(StringIO.new("0001Y\n")).file_name("orders.fixed").schema(schema).as(Order)

        error = assert_raises(IOStreams::Errors::IncompatibleType) { stream.each(:hash) { nil } }
        refute_kind_of IOStreams::Errors::InvalidHeader, error
        assert_includes error.message, 'The column "amount" holds values of type boolean, which the number field "amount" never accepts'
        assert_equal [error.message], stream.contract_errors.map(&:message)
        assert_raises(IOStreams::Errors::IncompatibleType) { stream.validate_contract! }
      end

      it "is not checked when writing, which converts each value written" do
        output = StringIO.new
        IOStreams.stream(output).file_name("orders.csv").schema(fields: [{name: "on", type: "date"}]).
          as(fields: [{name: "on", type: "datetime"}]).writer(:hash) { |io| io << {"on" => Time.utc(2026, 10, 25)} }

        assert_equal "on\n2026-10-25\n", output.string
      end

      it "is not checked for text, which is parsed, nor for JSON, each of whose values has its own type" do
        assert upload("ID,Amount\n1,true\n").validate_contract!
        assert upload(%({"id":1,"amount":true}\n), "orders.json").validate_contract!
      end

      describe "of a Parquet file" do
        before do
          skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)
        end

        it "raises before the first row" do
          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "orders.parquet")
            path.schema(fields: [{name: "id", type: "integer"}, {name: "amount", type: "boolean"}]).writer(:hash) do |io|
              io << {"id" => 1, "amount" => true}
            end

            rows = []
            assert_raises(IOStreams::Errors::IncompatibleType) do
              IOStreams.path(dir, "orders.parquet").as(Order).each(:hash) { |row| rows << row }
            end
            assert_empty rows
            assert_equal 1, IOStreams.path(dir, "orders.parquet").as(Order).contract_errors.size
          end
        end

        it "matches the columns of a Parquet file by name, in any order, as reading does" do
          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "orders.parquet")
            path.schema(fields: [{name: "amount", type: "integer"}, {name: "id", type: "integer"}]).writer(:hash) do |io|
              io << {"id" => 1, "amount" => 2}
            end
            contract = IOStreams::Contract.new(fields: [{name: "id", type: "integer"}, {name: "amount", type: "number"}])

            assert IOStreams.path(dir, "orders.parquet").as(contract).validate_contract!
            assert_empty IOStreams.path(dir, "orders.parquet").as(contract).contract_errors
          end
        end

        it "converts a type that loses nothing, such as an integer to a number" do
          Dir.mktmpdir do |dir|
            path = IOStreams.path(dir, "orders.parquet")
            path.schema(fields: [{name: "id", type: "number", decimals: 0}, {name: "amount", type: "integer"}]).writer(:hash) do |io|
              io << {"id" => BigDecimal("7"), "amount" => 12}
            end

            assert IOStreams.path(dir, "orders.parquet").as(Order).validate_contract!
            records = []
            IOStreams.path(dir, "orders.parquet").as(Order).each(:hash) { |record| records << record }

            assert_equal [{"id" => 7, "amount" => BigDecimal("12"), "ordered_at" => nil}], records
          end
        end
      end
    end

    describe "#infer_schema with a contract" do
      it "returns the schema that the source declares, which the contract meets" do
        assert_equal [{name: "id", type: "string"}], upload("ID\n1\n").infer_schema.to_h[:fields]
      end
    end
  end

  describe IOStreams::Schema::Field do
    # Returns [IOStreams::Schema::Field] a field of the supplied type.
    def field(type)
      IOStreams::Schema.new(fields: [{name: "value", type: type}]).fields.first
    end

    describe "#converts?" do
      it "takes a column of its own type, and of a type that converts without loss" do
        assert field("number").converts?("integer")
        assert field("integer").converts?("number")
        assert field("date").converts?("datetime")
        assert field("time").converts?("datetime")
        refute field("datetime").converts?("date")
        refute field("number").converts?("boolean")
        refute field("boolean").converts?("integer")
      end

      it "takes text and values of type any in every field but a string, which takes neither an object nor an array" do
        %w[integer number boolean date datetime time object array].each do |type|
          assert field(type).converts?("string"), "a #{type} field takes text"
          assert field(type).converts?("any"), "a #{type} field takes any"
        end
        assert field("string").converts?("integer")
        refute field("string").converts?("object")
        refute field("string").converts?("array")
        assert field("any").converts?("object")
      end
    end
  end
end
