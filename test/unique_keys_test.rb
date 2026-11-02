# frozen_string_literal: true

require_relative "test_helper"

# The values of a field with the constraint `unique`, of the `primaryKey`, and of each of the `uniqueKeys` of a schema
# must be unique within each read or write of a file, as Frictionless defines them.
class UniqueKeysTest < Minitest::Test
  # A store of slices, see `IOStreams::Slice::Target`, of 2 rows each.
  class Store
    include IOStreams::Slice::Target

    attr_reader :slices

    def initialize
      @slices = []
    end

    def slice_size
      2
    end

    def write_slice(slice)
      @slices << slice
    end
  end

  describe "unique values" do
    # Returns [Array] the records read from the CSV text with the schema.
    def read(text, schema, mode = :hash, file_name: "people.csv", **)
      records = []
      IOStreams.stream(StringIO.new(text)).file_name(file_name).schema(schema).each(mode, **) { |record| records << record }
      records
    end

    # Returns [Array] the records read from a slice with the schema, as a worker reads them.
    def read_slice(slice, schema)
      records = []
      IOStreams.stream(slice).schema(schema).each(:hash) { |record| records << record }
      records
    end

    # Returns [Array<IOStreams::Slice>] the slices of 2 rows of the CSV text, read without a schema, so that nothing
    # checks their values while they are sliced.
    def slices_of(text)
      slices = []
      IOStreams.stream(StringIO.new(text)).file_name("a.csv").each(:slice, size: 2) { |slice| slices << slice }
      slices
    end

    # Returns [String] the text written for the records with the schema.
    def write(records, schema, mode = :hash, file_name: "people.csv")
      output = StringIO.new
      IOStreams.stream(output).file_name(file_name).schema(schema).writer(mode) do |io|
        records.each { |record| io << record }
      end
      output.string
    end

    describe "the unique constraint" do
      let(:schema) { {fields: [{name: "id", type: "integer", constraints: {unique: true}}, {name: "name"}]} }

      it "raises for a value read before, naming the field, the value, and the record and line" do
        assert_equal [{"id" => 1, "name" => "a"}, {"id" => 2, "name" => "b"}], read("id,name\n1,a\n2,b\n", schema)
        error = assert_raises(IOStreams::Errors::InvalidValue) { read("id,name\n1,a\n2,b\n01,c\n", schema) }

        assert_equal 'Field "id": "1" is not unique, it is the value of an earlier record', error.reason
        assert_equal "id", error.field
        assert_equal 1, error.value
        assert_equal 3, error.record_number
        assert_equal 4, error.line_number
      end

      it "compares the values as their field reads them, so that 1 and 01 are the same integer" do
        assert_raises(IOStreams::Errors::InvalidValue) { read("id,name\n1,a\n01,b\n", schema) }
      end

      it "does not compare nil, a missing value" do
        assert_equal 3, read("id,name\n,a\n,b\n1,c\n", schema).size
      end

      it "checks each read on its own" do
        2.times { assert_equal 1, read("id,name\n1,a\n", schema).size }
      end

      it "checks the rows read too, and JSON records" do
        assert_raises(IOStreams::Errors::InvalidValue) { read("id,name\n1,a\n1,b\n", schema, :array) }
        assert_raises(IOStreams::Errors::InvalidValue) do
          read(%({"id":1,"name":"a"}\n{"id":1,"name":"b"}\n), schema, file_name: "people.json")
        end
        assert_raises(IOStreams::Errors::InvalidValue) do
          read(%({"id":1,"name":"a"}\n{"id":1,"name":"b"}\n), schema, :array, file_name: "people.json")
        end
      end

      it "hands a duplicate to on_invalid, and keeps reading the records after it" do
        problems = []
        records  = read("id,name\n1,a\n1,b\n2,c\n", schema, on_invalid: ->(row) { problems << row })

        assert_equal [{"id" => 1, "name" => "a"}, {"id" => 2, "name" => "c"}], records
        assert_equal ['Field "id": "1" is not unique, it is the value of an earlier record'], problems.flat_map(&:errors).map(&:reason)
        assert_equal [2], problems.map(&:record_number)
      end

      it "names the value as its field writes it" do
        schema = {fields: [{name: "pay", type: "number", decimals: 2, constraints: {unique: true}}]}

        error = assert_raises(IOStreams::Errors::InvalidValue) { read("pay\n1\n1.00\n", schema) }
        assert_equal 'Field "pay": "1.00" is not unique, it is the value of an earlier record', error.reason
        error = assert_raises(IOStreams::Errors::InvalidValue) do
          write([{"pay" => 1.5}, {"pay" => BigDecimal("1.5")}], schema, file_name: "pay.json")
        end
        assert_equal 'Field "pay": "1.50" is not unique, it is the value of an earlier record', error.reason
      end

      it "does not remember the value of a record that raises, so a record after it can have it" do
        schema = {
          uniqueKeys: [["id"], ["code"]],
          fields:     [{name: "id", type: "integer"}, {name: "code"}, {name: "n", type: "integer"}]
        }
        problems = []
        records  = read("id,code,n\n1,a,1\n2,b,x\n2,a,3\n2,c,4\n", schema, on_invalid: ->(row) { problems << row })

        # The record of line 3 does not count, since its n is not valid, and that of line 4, since its code is not unique,
        # so neither its id 2, which was checked before its code, nor that of line 3 is remembered.
        assert_equal [{"id" => 1, "code" => "a", "n" => 1}, {"id" => 2, "code" => "c", "n" => 4}], records
        assert_equal [2, 3], problems.map(&:record_number)
      end

      it "remembers a copy of each value, which a change to the record read does not change" do
        schema = {uniqueKeys: [%w[first last]], fields: [{name: "first"}, {name: "last"}]}

        assert_raises(IOStreams::Errors::InvalidValue) do
          IOStreams.stream(StringIO.new("first,last\njack,jones\njack,jones\n")).file_name("a.csv").schema(schema).each(:hash) do |record|
            record["first"].upcase!
          end
        end
      end

      it "does not check the rows of a slice, which is only a part of a file, which slicing with validate: true checks" do
        text   = "id,name\n1,a\n1,b\n2,c\n1,d\n"
        slices = slices_of(text)

        assert_equal([2, 2], slices.map { |slice| read_slice(slice, schema).size })
        contract = IOStreams::Contract.new(primaryKey: "id", fields: [{name: "id", type: "integer"}, {name: "name"}])
        records  = []
        IOStreams.stream(slices.first).as(contract).each(:hash) { |record| records << record }

        assert_equal [{"id" => 1, "name" => "a"}, {"id" => 1, "name" => "b"}], records
        sliced = []
        IOStreams.stream(slices.first).schema(schema).each(:slice, size: 1, validate: true) { |slice| sliced << slice }

        assert_equal [1, 1], sliced.map(&:size)
        handed = []
        error  = assert_raises(IOStreams::Errors::InvalidValue) do
          IOStreams.stream(StringIO.new("id,name\n1,a\n2,b\n1,c\n")).file_name("a.csv").schema(schema).
            each(:slice, size: 2, validate: true) { |slice| handed << slice }
        end
        assert_equal [2], handed.map(&:size)
        assert_equal 3, error.record_number
      end

      it "still checks the other constraints of the rows of a slice, such as the required fields of a primaryKey" do
        slice = slices_of("id,name\n,a\n").first

        assert_raises(IOStreams::Errors::InvalidValue) { read_slice(slice, {primaryKey: "id", fields: schema[:fields]}) }
      end

      it "checks every row of the file written to a store of slices with validate: true, across its slices" do
        store = Store.new
        error = assert_raises(IOStreams::Errors::InvalidValue) do
          IOStreams.stream(store).format(:csv).schema(schema).writer(:line, validate: true) do |io|
            %w[id,name 1,a 2,b 1,c].each { |line| io << line }
          end
        end

        assert_equal 3, error.record_number
        assert_equal [2], store.slices.map(&:size)
        store = Store.new
        assert_raises(IOStreams::Errors::InvalidValue) do
          IOStreams.stream(store).schema(schema).copy_from(StringIO.new("id,name\n1,a\n2,b\n1,c\n"), mode: :line, validate: true)
        end
        assert_equal [2], store.slices.map(&:size)
      end

      it "does not check the lines written to a store of slices without validate: true, but a writer of records checks its own" do
        store = Store.new
        IOStreams.stream(store).format(:csv).schema(schema).writer(:line) do |io|
          %w[id,name 1,a 2,b 1,c].each { |line| io << line }
        end

        assert_equal [2, 1], store.slices.map(&:size)
        store = Store.new
        assert_raises(IOStreams::Errors::InvalidValue) do
          IOStreams.stream(store).format(:csv).schema(schema).writer(:hash) do |io|
            [{"id" => 1}, {"id" => 2}, {"id" => 1}].each { |record| io << record }
          end
        end
      end

      it "checks every row of the slices written to a file with validate: true, across the slices" do
        slices = slices_of("id,name\n1,a\n2,b\n1,c\n")
        output = StringIO.new
        IOStreams.stream(output).file_name("a.csv").schema(schema).writer(:slice) do |io|
          slices.each { |slice| io << slice }
        end

        assert_equal "id,name\n1,a\n2,b\n1,c\n", output.string
        error = assert_raises(IOStreams::Errors::InvalidValue) do
          IOStreams.stream(StringIO.new).file_name("a.csv").schema(schema).writer(:slice, validate: true) do |io|
            slices.each { |slice| io << slice }
          end
        end
        assert_equal 3, error.record_number
      end

      it "raises for a value written before" do
        assert_equal "id,name\n1,a\n2,b\n", write([{"id" => 1, "name" => "a"}, {"id" => 2, "name" => "b"}], schema)
        assert_raises(IOStreams::Errors::InvalidValue) { write([{"id" => 1, "name" => "a"}, {"id" => "1", "name" => "b"}], schema) }
        assert_raises(IOStreams::Errors::InvalidValue) { write([[1, "a"], [1, "b"]], schema, :array) }
        assert_raises(IOStreams::Errors::InvalidValue) do
          write([{"id" => 1, "name" => "a"}, {"id" => 1, "name" => "b"}], schema, file_name: "people.json")
        end
      end

      it "raises for a value of unique that is not true or false" do
        assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [{name: "id", constraints: {unique: "yes"}}]) }
      end
    end

    describe "primaryKey" do
      let(:schema) do
        {
          primaryKey: %w[region id],
          fields:     [{name: "region"}, {name: "id", type: "integer"}, {name: "name"}]
        }
      end

      it "raises for a key whose values of every field together were read before" do
        assert_equal 3, read("region,id,name\nUS,1,a\nCA,1,b\nUS,2,c\n", schema).size
        error = assert_raises(IOStreams::Errors::InvalidValue) { read("region,id,name\nUS,1,a\nCA,1,b\nUS,1,c\n", schema) }

        assert_equal 'The primaryKey "region", "id": "US", "1" is not unique, it is the value of an earlier record', error.reason
        assert_equal %w[region id], error.field
        assert_equal ["US", 1], error.value
        assert_equal 3, error.record_number
      end

      it "makes each of its fields required, as Frictionless does" do
        fields = IOStreams::Schema.new(schema).fields

        assert_equal [true, true, false], fields.map(&:required?)
        assert_equal({name: "region"}, fields.first.to_h)
        error = assert_raises(IOStreams::Errors::InvalidValue) { read("region,id,name\nUS,,a\n", schema) }
        assert_equal 'Field "id" is required, but has no value', error.reason
        assert_raises(IOStreams::Errors::InvalidHeader) { read("region,name\nUS,a\n", schema.merge(fieldsMatch: "partial")) }
      end

      it "names a field by a Symbol too, as a field can be named" do
        schema = {primaryKey: [:id], uniqueKeys: [[:code]], fields: [{name: :id, type: "integer"}, {name: "code"}]}

        assert_raises(IOStreams::Errors::InvalidValue) { read("id,code\n1,a\n1,b\n", schema) }
        assert_raises(IOStreams::Errors::InvalidValue) { read("id,code\n1,a\n2,a\n", schema) }
      end

      it "takes the name of one field, as Frictionless v1 wrote it" do
        schema = {primaryKey: "id", fields: [{name: "id", type: "integer"}]}

        assert_raises(IOStreams::Errors::InvalidValue) { read("id\n1\n1\n", schema) }
        assert_equal({primaryKey: "id", fields: [{name: "id", type: "integer"}]}, IOStreams::Schema.new(schema).to_h)
      end

      it "raises for a key that is not the names of fields, or names one twice, or a field that allows blank values" do
        [
          {primaryKey: [], fields: [{name: "id"}]}, {primaryKey: [1], fields: [{name: "id"}]},
          {primaryKey: %w[id id], fields: [{name: "id"}]}, {primaryKey: ["code"], fields: [{name: "id"}]},
          {primaryKey: 1, fields: [{name: "id"}]}, {primaryKey: "id", fields: [{name: "id", allowBlank: true}]},
          {primaryKey: "id", fields: [{name: "id", skip: true}, {name: "a"}]}
        ].each do |descriptor|
          assert_raises(ArgumentError, descriptor.inspect) { IOStreams::Schema.new(descriptor) }
        end
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(primaryKey: ["code"], fields: [{name: "id"}]) }
        assert_equal 'The schema primaryKey names "code", which is not a field of the schema', error.message
      end
    end

    describe "uniqueKeys" do
      let(:schema) do
        {
          uniqueKeys: [["email"], %w[first last]],
          fields:     [{name: "email"}, {name: "first"}, {name: "last"}]
        }
      end

      it "checks each key on its own" do
        assert_equal 2, read("email,first,last\na@x,Jack,Jones\nb@x,Jack,Smith\n", schema).size
        error = assert_raises(IOStreams::Errors::InvalidValue) { read("email,first,last\na@x,Jack,Jones\nb@x,Jack,Jones\n", schema) }
        assert_equal 'The uniqueKey "first", "last": "Jack", "Jones" is not unique, it is the value of an earlier record',
                     error.reason
        error = assert_raises(IOStreams::Errors::InvalidValue) { read("email,first,last\na@x,Jack,Jones\na@x,Jill,Jones\n", schema) }
        assert_equal 'The uniqueKey "email": "a@x" is not unique, it is the value of an earlier record', error.reason
      end

      it "does not compare a key whose value of any field is nil, as SQL does" do
        assert_equal 3, read("email,first,last\n,Jack,\n,Jack,\n,,Jones\n", schema).size
      end

      it "raises for keys that are not Arrays of the names of fields, none at all, or a field with skip: true" do
        [[], [[]], ["email"], [[1]], [["code"]], [%w[email email]], "email"].each do |keys|
          assert_raises(ArgumentError, keys.inspect) { IOStreams::Schema.new(schema.merge(uniqueKeys: keys)) }
        end
        error = assert_raises(ArgumentError) do
          IOStreams::Schema.new(uniqueKeys: [["code"]], fields: [{name: "id"}, {name: "code", skip: true}])
        end
        assert_equal 'The schema uniqueKeys names "code", a field with skip: true, whose values are never read', error.message
      end
    end

    describe "uniqueLimit" do
      let(:schema) { {uniqueLimit: 2, fields: [{name: "id", type: "integer", constraints: {unique: true}}]} }

      it "raises UniqueLimitExceeded, which is not an InvalidValue, for a value beyond the most it remembers" do
        assert_equal 2, read("id\n1\n2\n", schema).size
        assert_raises(IOStreams::Errors::InvalidValue) { read("id\n1\n2\n2\n", schema) }
        error = assert_raises(IOStreams::Errors::UniqueLimitExceeded) { read("id\n1\n2\n3\n", schema) }

        refute_kind_of IOStreams::Errors::InvalidValue, error
        assert_kind_of IOStreams::Errors::Error, error
        assert_includes error.message, 'Field "id": the uniqueness of its values cannot be checked beyond 2 distinct values'
      end

      it "is not handed to on_invalid, since the value may be unique" do
        assert_raises(IOStreams::Errors::UniqueLimitExceeded) { read("id\n1\n2\n3\n", schema, on_invalid: ->(_row) {}) }
      end

      it "defaults to 1,000,000, and must be a positive Integer" do
        assert_equal 1_000_000, IOStreams::Schema::UNIQUE_LIMIT
        [0, -1, 1.5, "10"].each do |limit|
          assert_raises(ArgumentError, limit.inspect) { IOStreams::Schema.new(schema.merge(uniqueLimit: limit)) }
        end
      end
    end

    describe "a contract" do
      it "checks the unique fields and keys of the contract, and of the schema of the file" do
        contract = IOStreams::Contract.new(fieldsMatch: "partial", primaryKey: "id", fields: [{name: "id", type: "integer"}])
        schema   = {fields: [{name: "id", type: "integer"}, {name: "code", constraints: {unique: true}}]}
        records  = []

        assert_raises(IOStreams::Errors::InvalidValue) do
          IOStreams.stream(StringIO.new("id,code\n1,a\n1,b\n")).file_name("a.csv").as(contract).each(:hash) { |r| records << r }
        end
        assert_raises(IOStreams::Errors::InvalidValue) do
          IOStreams.stream(StringIO.new("id,code\n1,a\n2,a\n")).file_name("a.csv").schema(schema).as(contract).each(:hash) do |r|
            records << r
          end
        end
      end

      it "remembers the values of a record only once both the schema of the file and the contract accept it" do
        contract = IOStreams::Contract.new(
          fieldsMatch: "partial",
          fields:      [{name: "id", type: "integer"}, {name: "status", constraints: {enum: %w[open closed]}}]
        )
        schema   = {fields: [{name: "id", type: "integer", constraints: {unique: true}}, {name: "status"}]}
        problems = []
        records  = []
        stream   = IOStreams.stream(StringIO.new("id,status\n1,bad\n1,open\n1,closed\n")).file_name("a.csv")
        stream.schema(schema).as(contract).each(:hash, on_invalid: ->(row) { problems << row }) { |record| records << record }

        assert_equal [{"id" => 1, "status" => "open"}], records
        assert_equal [1, 3], problems.map(&:record_number)
      end

      it "remembers the values of a record written only once both the contract and the schema of the file accept it" do
        contract = IOStreams::Contract.new(primaryKey: "id", fields: [{name: "id", type: "integer"}, {name: "n", type: "integer"}])
        schema   = {fields: [{name: "id", type: "integer"}, {name: "n", type: "integer", constraints: {maximum: 5}}]}
        output   = StringIO.new
        IOStreams.stream(output).file_name("a.csv").schema(schema).as(contract).writer(:hash) do |io|
          assert_raises(IOStreams::Errors::InvalidValue) { io << {"id" => 1, "n" => 9} }
          io << {"id" => 1, "n" => 2}
          assert_raises(IOStreams::Errors::InvalidValue) { io << {"id" => 1, "n" => 3} }
        end

        assert_equal "id,n\n1,2\n", output.string
      end

      it "declares them with primary_key, unique_keys and unique_limit, which to_dsl writes" do
        contract = Class.new(IOStreams::Contract) do
          unique_limit 10
          field :id, :integer
          field :email, :string, constraints: {unique: true}
          primary_key "id"
          unique_keys [["email"]]
        end

        assert_equal({uniqueLimit: 10, primaryKey: "id", uniqueKeys: [["email"]],
                      fields: [{name: "id", type: "integer"}, {name: "email", type: "string", constraints: {unique: true}}]},
                     contract.to_h)
        dsl = contract.to_dsl("People")

        assert_equal(<<~RUBY, dsl)
          class People < IOStreams::Contract
            unique_limit 10

            field :id,    :integer
            field :email, :string,  constraints: {unique: true}

            primary_key "id"
            unique_keys [["email"]]
          end
        RUBY
        error = assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { primary_key "id" } }
        assert_equal 'The contract has no field named "id": declare primary_key after the fields that it names', error.message
        assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { unique_keys [["id"]] } }
        assert_equal contract.to_h, Class.new(IOStreams::Contract) { class_eval(dsl.lines[1..-2].join, __FILE__, __LINE__) }.to_h
      end
    end
  end
end
