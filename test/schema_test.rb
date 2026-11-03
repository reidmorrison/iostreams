# frozen_string_literal: true

require_relative "test_helper"
require "json"

class SchemaTest < Minitest::Test
  describe IOStreams::Schema do
    # Returns [IOStreams::Schema::Field] the only field of a schema with the supplied properties.
    def field(**properties)
      IOStreams::Schema.new(fields: [{name: "value", **properties}]).fields.first
    end

    describe ".new" do
      it "accepts String and Symbol keys" do
        schema = IOStreams::Schema.new("fields" => [{"name" => "id", "type" => "integer"}, {name: :age, type: :integer}])

        assert_equal ["id", :age], schema.fields.map(&:name)
        assert_equal %w[integer integer], schema.fields.map(&:type)
      end

      it "defaults the type to any, as Frictionless does" do
        assert_equal "any", field.type
      end

      it "accepts the properties that describe the schema, and those of other tools" do
        schema = IOStreams::Schema.new(
          "$schema"    => "https://datapackage.org/profiles/2.0/tableschema.json",
          :title       => "People",
          :description => "Everyone",
          "tool:owner" => "me",
          :fields      => [{name: "id", title: "Id", description: "Key", example: "1", rdfType: "x", "tool:x" => 1}]
        )

        assert_equal ["id"], schema.fields.map(&:name)
      end

      it "keeps a property that it does not know, as Frictionless allows, which has no effect" do
        schema = IOStreams::Schema.new(fields: [{name: "id", unit: "kg"}], profile: "tabular", "mytool:owner": "ops")

        assert_equal({profile: "tabular", "mytool:owner": "ops", fields: [{name: "id", unit: "kg"}]}, schema.to_h)
        assert_equal schema, IOStreams::Schema.new(JSON.parse(JSON.generate(schema.to_h)))
      end

      it "raises for a property of the schema that is close to one that it knows, which is most likely mistyped" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [], widht: 3) }
        assert_equal 'Unknown schema property "widht", which is close to "width": correct it, or name the property of ' \
                     'another tool with a prefix, such as "mytool:widht"', error.message
        %i[fieldMatch fieldsmatch primaryKeys keytype Header uniqueKey].each do |property|
          assert_raises(ArgumentError, property.inspect) { IOStreams::Schema.new(fields: [], property => 1) }
        end
      end

      it "raises for a property of Frictionless that is not supported, rather than ignore its rule" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [{name: "id"}], foreignKeys: []) }
        assert_equal 'The schema property "foreignKeys" is not supported', error.message
      end

      it "raises without an Array of fields" do
        assert_raises(ArgumentError) { IOStreams::Schema.new({}) }
        assert_raises(ArgumentError) { IOStreams::Schema.new(fields: {name: "id"}) }
      end

      it "raises when it is not a Hash" do
        assert_raises(ArgumentError) { IOStreams::Schema.new([{name: "id"}]) }
      end

      it "raises for a field without a name" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [{type: "integer"}]) }
        assert_match(/must have a name/, error.message)
      end

      it "accepts fields of the same name, as Frictionless requires, raising only for records keyed by them" do
        schema = IOStreams::Schema.new(fields: [{name: "id"}, {name: "id"}])

        assert_equal %w[id id], schema.fields.map(&:name)
        error = assert_raises(ArgumentError) { schema.check_record_keys }
        assert_equal 'The schema has two fields named "id", which Frictionless accepts, but a record holds each field by a ' \
                     "key of its own: read and write their rows, whose values are in the order of the fields, such as with " \
                     "each(:array) of a CSV file, or give each field a name of its own", error.message
        assert_nil IOStreams::Schema.new(fields: [{name: "id"}, {name: "name"}]).check_record_keys
      end

      it "raises for a property of a field that is close to one that it knows, which is most likely mistyped" do
        error = assert_raises(ArgumentError) { field(widht: 3) }
        assert_equal 'Field "value": unknown property "widht", which is close to "width": correct it, or name the property ' \
                     'of another tool with a prefix, such as "mytool:widht"', error.message
        [{type: "boolean", trueValue: ["y"]}, {type: "number", groupchar: ","}, {Constraints: {}}, {contraints: {}},
         {aliase: ["x"]}, {type: "number", decimal: 2}, {fromat: "%Y"}, {tpye: "string"}].each do |properties|
          assert_raises(ArgumentError, properties.inspect) { field(**properties) }
        end
      end

      it "keeps a property of a field that it does not know, also of a field with skip: true, which has no effect" do
        assert_equal({name: "value", unit: "kg", "mytool:x": 1}, field(unit: "kg", "mytool:x": 1).to_h)
        assert_equal({name: "value", skip: true, unit: "kg"}, field(skip: true, unit: "kg").to_h)
      end

      it "raises for a property of Frictionless of another type, rather than ignore its check" do
        error = assert_raises(ArgumentError) { field(delimiter: ";") }
        assert_equal 'Field "value": "delimiter" only applies to a list field', error.message
      end

      it "accepts the required constraint" do
        assert_predicate field(constraints: {required: true}), :required?
        assert_predicate field("constraints" => {"required" => true}), :required?
        refute_predicate field(constraints: {required: false}), :required?
        refute_predicate field(constraints: {}), :required?
        refute_predicate field, :required?
      end

      it "raises for the constraints of Frictionless that are not supported, and unknown ones" do
        error = assert_raises(ArgumentError) { field(constraints: {required: true, jsonSchema: {}}) }
        assert_equal 'Field "value": the constraint "jsonSchema" is not supported', error.message

        error = assert_raises(ArgumentError) { field(constraints: {mandatory: true}) }
        assert_equal 'Field "value": unknown constraint "mandatory"', error.message

        assert_raises(ArgumentError) { field(constraints: {required: "yes"}) }
        assert_raises(ArgumentError) { field(constraints: [:required]) }
      end

      it "accepts allowBlank for a required field, which is still required" do
        assert_predicate field(constraints: {required: true}, allowBlank: true), :required?
        assert_predicate field("constraints" => {"required" => true}, "allowBlank" => true), :required?
        refute_predicate field(allowBlank: false), :required?
      end

      it "raises for allowBlank on a field that is not required, or that is not true or false" do
        error = assert_raises(ArgumentError) { field(allowBlank: true) }
        assert_equal 'Field "value": allowBlank only applies to a field whose constraints are required, since the values ' \
                     "of any other field can be blank", error.message
        assert_raises(ArgumentError) { field(constraints: {required: false}, allowBlank: true) }

        error = assert_raises(ArgumentError) { field(constraints: {required: true}, allowBlank: "yes") }
        assert_equal 'Field "value": allowBlank must be true or false: "yes"', error.message
      end

      it "accepts aliases, which are names" do
        assert_equal ["DOB", "Birth Date"], field(aliases: ["DOB", "Birth Date"]).aliases
        assert_empty field.aliases
        assert_empty field(aliases: []).aliases
        assert_raises(ArgumentError) { field(aliases: "DOB") }
        assert_raises(ArgumentError) { field(aliases: [""]) }
        assert_raises(ArgumentError) { field(aliases: [:dob]) }
      end

      it "raises for empty true and false values, whose first value it writes" do
        assert_raises(ArgumentError) { field(type: "boolean", trueValues: []) }
        assert_raises(ArgumentError) { field(type: "boolean", falseValues: []) }
      end

      it "keeps its own copy of each name, so that changing the name supplied does not change the field" do
        name       = +"first_name"
        alias_name = +"First"
        field      = IOStreams::Schema.new(fields: [{name: name, aliases: [alias_name]}]).fields.first
        name.upcase!
        alias_name.upcase!

        assert_equal "first_name", field.name
        assert_predicate field.name, :frozen?
        assert_equal ["First"], field.aliases
        assert_equal :id, IOStreams::Schema.new(fields: [{name: :id}]).fields.first.name
      end

      it "raises for an alias that is the name or alias of another field, since either could be meant" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [{name: "id"}, {name: "key", aliases: ["id"]}]) }
        assert_equal 'Field "key": the alias "id" is already the name or an alias of the field "id"', error.message

        assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [{name: "a", aliases: ["x"]}, {name: "b", aliases: ["x"]}]) }
        assert_equal ["id"], IOStreams::Schema.new(fields: [{name: "id", aliases: ["id"]}]).fields.map(&:name)
      end

      it "defaults fieldsMatch to exact, as Frictionless does" do
        assert_equal "exact", IOStreams::Schema.new(fields: []).fields_match
        %w[exact equal subset superset partial].each do |fields_match|
          assert_equal fields_match, IOStreams::Schema.new(fields: [], fieldsMatch: fields_match).fields_match
        end
        assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [], fieldsMatch: "any") }
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [], fieldsMatch: :equal) }
        assert_equal 'The schema fieldsMatch must be one of "exact", "equal", "subset", "superset" and "partial": :equal',
                     error.message
      end

      it "accepts any fieldsMatch without a header row, which a format without a header row, such as JSON, ignores" do
        assert_equal "equal", IOStreams::Schema.new(fields: [{name: "id"}], header: false, fieldsMatch: "equal").fields_match
        assert_equal "exact", IOStreams::Schema.new(fields: [{name: "id"}], header: false).fields_match
      end

      it "raises for a property of another type of field" do
        error = assert_raises(ArgumentError) { field(type: "integer", decimals: 2) }
        assert_equal 'Field "value": "decimals" only applies to a list or number field', error.message
      end

      it "raises for a type of Frictionless that is not supported" do
        error = assert_raises(ArgumentError) { field(type: "geojson") }
        assert_equal 'Field "value": the type "geojson" is not supported', error.message
      end

      it "raises for an unknown type" do
        error = assert_raises(ArgumentError) { field(type: "money") }
        assert_equal 'Field "value": unknown type "money"', error.message
      end

      it "raises for a format of a string other than those of Frictionless" do
        assert_raises(ArgumentError) { field(type: "string", format: "url") }
      end

      it "accepts the default format" do
        assert_equal "2026-10-13", field(type: "date", format: "default").render(Date.new(2026, 10, 13), :text)
      end

      it "raises for an invalid width, start, decimals or flag" do
        assert_raises(ArgumentError) { field(width: 0) }
        assert_raises(ArgumentError) { field(width: "5") }
        assert_raises(ArgumentError) { field(start: 0) }
        assert_raises(ArgumentError) { field(type: "number", decimals: -1) }
        assert_raises(ArgumentError) { field(type: "string", truncate: "yes") }
        assert_raises(ArgumentError) { field(type: "boolean", trueValues: "Y") }
        assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [], width: 0) }
      end

      it "has a header row unless header is false" do
        assert_predicate IOStreams::Schema.new(fields: []), :header?
        refute_predicate IOStreams::Schema.new(fields: [{name: "id"}], header: false), :header?
        assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [], header: "no") }
      end

      it "accepts no fields without a header row, which a format without a header row, such as JSON, ignores" do
        refute_predicate IOStreams::Schema.new(fields: [], header: false), :header?
      end

      it "accepts a width of remainder" do
        assert_equal :remainder, field(width: "remainder").width
        assert_equal :remainder, IOStreams::Schema.new(fields: [], width: "remainder").width
      end
    end

    describe "#to_h" do
      it "returns the schema as it was given, with Symbol keys, its properties before its fields" do
        schema = IOStreams::Schema.new(
          "fields"      => [{"name" => "id", "type" => "integer", "constraints" => {"required" => true}},
                            {name: :zip, aliases: ["Zip Code"], "tool:x" => {"a" => 1}}],
          "fieldsMatch" => "subset",
          "title"       => "Orders"
        )

        assert_equal(
          {fieldsMatch: "subset", title: "Orders",
           fields: [{name: "id", type: "integer", constraints: {required: true}},
                    {name: :zip, aliases: ["Zip Code"], "tool:x": {"a" => 1}}]},
          schema.to_h
        )
      end

      it "returns a new Hash each time, which can be changed without changing the schema" do
        schema = IOStreams::Schema.new(fields: [{name: "id", type: "integer"}])
        hash   = schema.to_h
        hash[:fields].first[:type] = "string"
        hash[:fields] << {name: "name"}

        assert_equal({fields: [{name: "id", type: "integer"}]}, schema.to_h)
        refute_predicate hash, :frozen?
      end

      it "makes a schema that is equal to itself" do
        schema = IOStreams::Schema.new(fields: [{name: "id", type: "number", decimals: 2}], fieldsMatch: "partial")

        assert_equal schema, IOStreams::Schema.new(schema.to_h)
        assert_equal schema, IOStreams::Schema.new(JSON.parse(JSON.generate(schema.to_h)))
      end
    end

    describe "#==" do
      it "compares the properties and the fields" do
        schema = IOStreams::Schema.new("fields" => [{"name" => "id", "type" => "integer"}])

        assert_equal schema, IOStreams::Schema.new(fields: [{name: "id", type: "integer"}])
        assert_equal schema.hash, IOStreams::Schema.new(fields: [{name: "id", type: "integer"}]).hash
        assert schema.eql?(IOStreams::Schema.new(fields: [{name: "id", type: "integer"}]))
        refute_equal schema, IOStreams::Schema.new(fields: [{name: "id"}])
        refute_equal schema, IOStreams::Schema.new(fields: [{name: :id, type: "integer"}])
        refute_equal schema, IOStreams::Schema.new(fields: [{name: "id", type: "integer"}], fieldsMatch: "subset")
        refute_equal schema, schema.to_h
      end

      it "is eql? only for properties that are eql?, as a Hash key needs, which have the same hash" do
        whole = IOStreams::Schema.new(fields: [{name: "id", "x:scale" => 1}])
        float = IOStreams::Schema.new(fields: [{name: "id", "x:scale" => 1.0}])

        assert_equal whole, float
        refute whole.eql?(float)
        assert_nil({whole => 1}[float])
        assert_equal 1, {whole => 1}[IOStreams::Schema.new(fields: [{name: "id", "x:scale" => 1}])]
        refute whole.fields.first.eql?(float.fields.first)
        assert_equal whole.fields.first.hash, IOStreams::Schema.new(whole.to_h).fields.first.hash
      end
    end

    describe "#inspect" do
      it "shows the schema as a Hash" do
        hash = {fields: [{name: "id", type: "integer"}]}

        # Ruby 3.4 shows a Hash as `{fields: [...]}`, earlier versions as `{:fields=>[...]}`.
        assert_equal "#<IOStreams::Schema #{hash.inspect}>", IOStreams::Schema.new(hash).inspect
      end
    end

    describe ".read" do
      it "reads the schema from a JSON file" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.json")
          path.write(JSON.generate(fields: [{name: "id", type: "integer"}]))

          assert_equal ["id"], IOStreams::Schema.read(path.to_s).fields.map(&:name)
          assert_equal ["id"], IOStreams::Schema.read(path).fields.map(&:name)
        end
      end

      it "reads the schema through the streams of its file name" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.json.gz")
          path.write(JSON.generate(fields: [{name: "id", type: "integer"}]))

          assert_equal ["id"], IOStreams::Schema.read(path.to_s).fields.map(&:name)
        end
      end

      it "ignores the byte order mark that some editors write at the start of a UTF-8 file, as reading rows does" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.json")
          path.write("\xEF\xBB\xBF#{JSON.generate(fields: [{name: 'id', type: 'integer'}])}".b)

          assert_equal ["id"], IOStreams::Schema.read(path.to_s).fields.map(&:name)
          assert_equal ["id"], IOStreams::Schema.read(IOStreams.path(path.to_s).raw).fields.map(&:name)
        end
      end

      it "names the file when it is not JSON, or not a valid schema" do
        Dir.mktmpdir do |dir|
          path = IOStreams.path(dir, "people.json")
          path.write("{")
          error = assert_raises(ArgumentError) { IOStreams::Schema.read(path.to_s) }
          assert_match(/\AInvalid schema in .*people\.json: /, error.message)

          path.write(JSON.generate(fields: [{name: "id", type: "geojson"}]))
          error = assert_raises(ArgumentError) { IOStreams::Schema.read(path.to_s) }
          assert_match(/people\.json: Field "id": the type "geojson" is not supported\z/, error.message)
        end
      end
    end

    describe ".match_key" do
      it "compares letters and digits, in every language, without their case" do
        assert_equal "firstname", IOStreams::Schema.match_key("First Name")
        assert_equal "firstname", IOStreams::Schema.match_key("first_name")
        assert_equal "firstname", IOStreams::Schema.match_key("first.name")
        assert_equal "firstname", IOStreams::Schema.match_key(:FIRSTNAME)
        assert_equal "firstname", IOStreams::Schema.match_key("FirstName")
        assert_equal "email", IOStreams::Schema.match_key(" E-mail ")
        assert_equal "prénom", IOStreams::Schema.match_key("PRÉNOM")
        assert_equal "日付", IOStreams::Schema.match_key("日付")
        assert_equal "strasse", IOStreams::Schema.match_key("Straße")
      end

      it "makes the forms of a character that Unicode treats as the same the same" do
        assert_equal "id", IOStreams::Schema.match_key("ＩＤ")
        assert_equal IOStreams::Schema.match_key("Pr\u00E9nom"), IOStreams::Schema.match_key("Pre\u0301nom")
        assert_equal "firstname", IOStreams::Schema.match_key("First\u00A0Name")
      end

      it "returns nil without letters or digits" do
        assert_nil IOStreams::Schema.match_key("#")
        assert_nil IOStreams::Schema.match_key("")
        assert_nil IOStreams::Schema.match_key(" - ")
      end

      it "compares the ASCII letters of text that is not Unicode" do
        assert_equal "name", IOStreams::Schema.match_key("Na\xE9me".b)
        assert_nil IOStreams::Schema.match_key("\xFF".dup.force_encoding("UTF-8"))
      end
    end

    describe "a field that is skipped" do
      it "takes only the properties that place its column" do
        field = IOStreams::Schema::Field.new({name: "filler", skip: true, type: "any", width: 3, start: 4, aliases: ["x"], title: "Filler", "tool:x" => 1})

        assert_predicate field, :skip?
        refute_predicate IOStreams::Schema::Field.new({name: "id"}), :skip?
        refute_predicate IOStreams::Schema::Field.new({name: "id", skip: false, type: "integer"}), :skip?
      end

      it "raises for a type, constraints or any other property that reads its values" do
        [{type: "integer"}, {constraints: {required: true}}, {format: "%Y"}, {truncate: true}].each do |property|
          error = assert_raises(ArgumentError) { IOStreams::Schema::Field.new({name: "filler", skip: true, **property}) }
          assert_equal "Field \"filler\": #{property.keys.first.to_s.inspect} does not apply to a field with skip: true, which only " \
                       "holds the place of its column, since its values are not read", error.message
        end
      end

      it "raises for a skip that is not true or false" do
        error = assert_raises(ArgumentError) { IOStreams::Schema::Field.new({name: "filler", skip: "yes"}) }
        assert_equal 'Field "filler": skip must be true or false: "yes"', error.message
      end
    end

    describe "extraColumns" do
      it "keeps the columns that the schema does not list only with a fieldsMatch that accepts them" do
        assert_predicate IOStreams::Schema.new(fields: [], fieldsMatch: "subset", extraColumns: "keep"), :keep_extra?
        assert_predicate IOStreams::Schema.new(fields: [], fieldsMatch: "partial", extraColumns: "keep"), :keep_extra?
        refute_predicate IOStreams::Schema.new(fields: [], fieldsMatch: "partial", extraColumns: "skip"), :keep_extra?
        refute_predicate IOStreams::Schema.new(fields: [], fieldsMatch: "exact", extraColumns: "skip"), :keep_extra?
        refute_predicate IOStreams::Schema.new(fields: []), :keep_extra?

        %w[exact equal superset].each do |fields_match|
          error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [], fieldsMatch: fields_match, extraColumns: "keep") }
          assert_equal "The schema extraColumns \"keep\" keeps the columns that the schema does not list, which fieldsMatch " \
                       "#{fields_match.inspect} does not accept; \"subset\" and \"partial\" accept them", error.message
        end
      end

      it "raises for a value that it does not know" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [], fieldsMatch: "subset", extraColumns: true) }
        assert_equal 'The schema extraColumns must be one of "skip" and "keep": true', error.message
      end
    end

    describe "#key_for" do
      it "forms the key of a name as keyType says" do
        keys = %w[string cleansed symbol cleansedSymbol].map do |key_type|
          schema = IOStreams::Schema.new(fields: [], keyType: key_type)
          [schema.key_for("First Name"), schema.key_for(:Zip)]
        end

        assert_equal [["First Name", "Zip"], %w[first_name zip], [:"First Name", :Zip], %i[first_name zip]], keys
      end

      it "keeps the names as they are given without keyType" do
        schema = IOStreams::Schema.new(fields: [{name: "First Name"}, {name: :zip}])

        assert_nil schema.key_type
        assert_equal(["First Name", :zip], schema.fields.map { |field| schema.key(field) })
      end

      it "returns frozen Strings, which a record uses as its keys without copying them" do
        schema = IOStreams::Schema.new(fields: [], keyType: "cleansed")

        assert_predicate schema.key_for(+"First Name"), :frozen?
        assert_predicate IOStreams::Schema.new(fields: []).key_for(+"Name"), :frozen?
      end

      it "raises for a keyType that it does not know" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [], keyType: "upcase") }
        assert_equal 'The schema keyType must be one of "string", "cleansed", "symbol" and "cleansedSymbol": "upcase"', error.message
      end

      it "raises for two fields with the same key, which a record could not hold" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [{name: "First Name"}, {name: "first-name"}], keyType: "cleansed") }
        assert_equal 'The fields "First Name" and "first-name" both have the key "first_name", which keyType "cleansed" forms from ' \
                     "their names, but a record read holds each field by a key of its own", error.message
      end

      it "raises for a key that is the name or an alias of another field, since a column of that name could be either" do
        error = assert_raises(ArgumentError) do
          IOStreams::Schema.new(fields: [{name: "First Name"}, {name: "given", aliases: ["first_name"]}], keyType: "cleansed")
        end
        assert_equal 'Field "given": the alias "first_name" is already the name or an alias of the field "First Name"', error.message

        error = assert_raises(ArgumentError) do
          IOStreams::Schema.new(fields: [{name: "given", aliases: ["first_name"]}, {name: "First Name"}], keyType: "cleansed")
        end
        assert_equal 'Field "First Name": its key "first_name", which keyType "cleansed" forms, is already the name or an alias ' \
                     'of the field "given"', error.message
      end

      it "matches a column or key that is the key of a field to the field" do
        schema = IOStreams::Schema.new(fields: [{name: "Area (m²)"}], keyType: "cleansed")

        assert_equal "Area (m²)", schema.field_for("area_m").name
      end
    end

    describe "#field_for" do
      let(:schema) do
        IOStreams::Schema.new(
          fields: [
            {name: "first_name"},
            {name: :age},
            {name: "Zip Code"},
            {name: "date_of_birth", aliases: ["DOB", "Birth Date"]},
            {name: "Amount ($)"},
            {name: "Amount (€)"}
          ]
        )
      end

      it "finds the field with the same name, whether it is a String or a Symbol" do
        assert_equal "first_name", schema.field_for("first_name").name
        assert_equal "first_name", schema.field_for(:first_name).name
        assert_equal :age, schema.field_for("age").name
      end

      it "finds the field whose name is the same once both are compared loosely" do
        assert_equal "first_name", schema.field_for("First Name").name
        assert_equal "first_name", schema.field_for("FIRST.NAME").name
        assert_equal "first_name", schema.field_for("FirstName").name
        assert_equal "Zip Code", schema.field_for("ZipCode").name
        assert_equal "Zip Code", schema.field_for("zip_code").name
        assert_equal :age, schema.field_for(" AGE ").name
      end

      it "finds the field of an alias, exactly or loosely" do
        assert_equal "date_of_birth", schema.field_for("DOB").name
        assert_equal "date_of_birth", schema.field_for("birth_date").name
        assert_equal "date_of_birth", schema.field_for("Date of Birth").name
      end

      it "finds a field by its name before comparing loosely, even when several fields are the same loosely" do
        assert_equal "Amount ($)", schema.field_for("Amount ($)").name
        assert_equal "Amount (€)", schema.field_for("Amount (€)").name
      end

      it "raises for a column that is several fields loosely, since either could be meant" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) { schema.field_for("amount") }
        assert_match(/\AThe column "amount" could be any of the fields "Amount \(\$\)" and "Amount \(€\)"/, error.message)

        error = assert_raises(IOStreams::Errors::InvalidHeader) { schema.field_for("AMOUNT", "key") }
        assert_match(/\AThe key "AMOUNT"/, error.message)
      end

      it "returns nil when no field is the column" do
        assert_nil schema.field_for("last_name")
        assert_nil schema.field_for("#")
        assert_nil schema.field_for("")
        assert_nil schema.field_for(nil)
      end

      it "returns nil for a column whose bytes are not valid in its encoding, rather than raise as it cleanses it" do
        invalid = (+"Caf\xE9").force_encoding(Encoding::UTF_8)

        assert_nil schema.field_for(invalid)
        assert_nil IOStreams::Schema.new(fields: [{name: "_"}, {name: "id"}]).field_for(invalid)
      end

      it "finds the field named as the column once cleansed, whose characters that Unicode makes digits it drops" do
        cleansed = IOStreams::Schema.new(fields: [{name: "area_m"}, {name: "score"}, {name: "Rate (½)"}])

        assert_equal "area_m", cleansed.field_for("Area (m²)").name
        assert_equal "score", cleansed.field_for("Score ①").name
        assert_equal "Rate (½)", cleansed.field_for("rate_").name
        assert_equal "Rate (½)", cleansed.field_for("rate").name
      end

      it "finds the field named as the column once cleansed, when several fields are the same loosely" do
        both = IOStreams::Schema.new(fields: [{name: "e_mail"}, {name: "email"}])

        assert_equal "e_mail", both.field_for("E-mail").name
        assert_equal "email", both.field_for("Email").name
        assert_equal "e_mail", both.field_for(" E MAIL ").name
      end

      it "still raises for a column that is several fields loosely, and none of them once cleansed" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) do
          IOStreams::Schema.new(fields: [{name: "na_me"}, {name: "n_ame"}]).field_for("Name")
        end
        assert_match(/\AThe column "Name" could be any of the fields "na_me" and "n_ame"/, error.message)
        assert_raises(IOStreams::Errors::InvalidHeader) { schema.field_for("amount_") }
      end

      it "finds the field named as a column without letters or digits once cleansed" do
        assert_equal "_", IOStreams::Schema.new(fields: [{name: "_"}, {name: "id"}]).field_for(" _ ").name
        assert_nil IOStreams::Schema.new(fields: [{name: "id"}]).field_for(" _ ")
      end

      it "finds the field whose name keeps the digits that Unicode makes of such characters first" do
        both = IOStreams::Schema.new(fields: [{name: "area_m2"}, {name: "area_m"}])

        assert_equal "area_m2", both.field_for("Area (m²)").name
        assert_equal "area_m", both.field_for("Area (m)").name
        assert_equal "area_m2", IOStreams::Schema.new(fields: [{name: "area_m2"}]).field_for("Area (m²)").name
      end
    end

    describe "#check_columns" do
      let(:id_field) { {name: "id"} }
      let(:name_field) { {name: "name"} }

      # Returns [String|nil] the message that checking the columns raises, or nil when it does not raise.
      def check(fields_match, labels, ordered: true, noun: "column", fields: [id_field, name_field])
        schema = IOStreams::Schema.new(fields: fields, fieldsMatch: fields_match)
        found  = labels.filter_map { |label| schema.field_for(label) }
        schema.check_columns(found, labels.reject { |label| schema.field_for(label) }, ordered: ordered, noun: noun)
        nil
      rescue IOStreams::Errors::InvalidHeader => e
        e.message
      end

      it "exact: the columns are the fields, in the same order" do
        assert_nil check("exact", %w[id name])
        assert_match(/the columns are not in the order of the fields, "id" and "name", which fieldsMatch "exact" requires/,
                     check("exact", %w[name id]))
        assert_match(/missing the field "name", which fieldsMatch "exact" requires/, check("exact", %w[id]))
        assert_match(/the column "x" is not a field of the schema, which fieldsMatch "exact" does not accept/, check("exact", %w[id name x]))
      end

      it "exact: accepts the keys of a record in any order" do
        assert_nil check("exact", %w[name id], ordered: false, noun: "key")
      end

      it "equal: the columns are the fields, in any order" do
        assert_nil check("equal", %w[name id])
        assert_match(/missing the field "name"/, check("equal", %w[id]))
        assert_match(/the column "x" is not a field/, check("equal", %w[name id x]))
      end

      it "subset: the columns include every field" do
        assert_nil check("subset", %w[x name id y])
        assert_match(/missing the field "name", which fieldsMatch "subset" requires/, check("subset", %w[id x]))
      end

      it "superset: every column is a field" do
        assert_nil check("superset", %w[name])
        assert_nil check("superset", [])
        assert_match(/the columns "x" and "y" are not fields of the schema, which fieldsMatch "superset" does not accept/,
                     check("superset", %w[id x y]))
      end

      it "partial: at least one column is a field" do
        assert_nil check("partial", %w[x name])
        assert_match(/no column is a field of the schema, but fieldsMatch "partial" needs at least one/, check("partial", %w[x y]))
      end

      it "requires a required field whatever fieldsMatch is" do
        fields = [id_field, {name: "name", constraints: {required: true}}]

        assert_match(/missing the required field "name"\z/, check("superset", %w[id], fields: fields))
        assert_match(/missing the required field "name"\z/, check("partial", %w[id x], fields: fields))
        assert_nil check("partial", %w[name], fields: fields)
      end

      it "names the input, and counts the columns without a name" do
        assert_match(/\AThe header row does not match the schema: a column without a name is not a field/, check("equal", ["id", "name", nil]))
        assert_match(/2 columns without a name are not fields/, check("equal", ["id", "", "name", " "]))
        assert_match(/\AThe keys of a record do not match the schema: the key "x" is not a field/, check("equal", %w[id name x], noun: "key"))
      end

      it "lists every problem" do
        assert_match(/"x" is not a field .*; missing the field "name"/, check("equal", %w[id x]))
      end
    end

    describe "#check_unknown" do
      it "raises for the keys or values that are not fields, unless fieldsMatch skips them" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) do
          IOStreams::Schema.new(fields: [{name: "id"}]).check_unknown(["x"], noun: "key")
        end
        assert_match(/\AThe keys of a record do not match the schema: the key "x" is not a field/, error.message)

        error = assert_raises(IOStreams::Errors::InvalidHeader) do
          IOStreams::Schema.new(fields: [{name: "id"}], fieldsMatch: "superset").check_unknown([1, 2], noun: "value")
        end
        assert_match(/\AThe values of a row do not match the schema: 2 values after the last field/, error.message)

        assert_nil IOStreams::Schema.new(fields: [{name: "id"}], fieldsMatch: "subset").check_unknown(["x"], noun: "key")
        assert_nil IOStreams::Schema.new(fields: [{name: "id"}]).check_unknown([], noun: "key")
      end

      it "names what the values of a row come after" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) do
          IOStreams::Schema.new(fields: [{name: "id"}]).check_unknown([1], noun: "value", last: "column")
        end
        assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)
      end

      it "does not suggest a fieldsMatch that skips them when the columns are the fields in order, which only accepts exact" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) do
          IOStreams::Schema.new(fields: [{name: "id"}], header: false).check_unknown([1], noun: "value", fields_in_order: true)
        end
        assert_equal "The values of a row do not match the schema: 1 value after the last field, which rows without a " \
                     "header row, such as of a schema with header: false, do not accept, since their columns are the " \
                     "fields in order", error.message
      end

      it "suggests a fieldsMatch that skips them without a header row, for a format whose columns are not the fields in order" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) do
          IOStreams::Schema.new(fields: [{name: "id"}], header: false).check_unknown(["age"], noun: "key")
        end
        assert_equal "The keys of a record do not match the schema: the key \"age\" is not a field of the schema, which " \
                     "fieldsMatch \"exact\" does not accept; \"subset\" and \"partial\" skip them", error.message
      end
    end

    describe "#check_fields_in_order" do
      it "raises for a fieldsMatch other than exact, or no fields, since the columns are the fields in order" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [{name: "id"}], header: false, fieldsMatch: "equal").check_fields_in_order }
        assert_equal "Rows without a header row, such as of a schema with header: false, have the fields of the schema " \
                     'in order, so its fieldsMatch must be "exact": "equal"', error.message

        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [], header: false).check_fields_in_order }
        assert_equal "Rows without a header row, such as of a schema with header: false, are read by the fields of the " \
                     "schema, in order, so it needs fields", error.message
        assert_nil IOStreams::Schema.new(fields: [{name: "id"}], header: false).check_fields_in_order
      end
    end

    describe "#projection" do
      def schema(fields_match, names = %w[first_name ID])
        IOStreams::Schema.new(fieldsMatch: fields_match, fields: names.map { |name| {name: name} })
      end

      it "returns the columns of the fields, in the order of the columns, when the others are skipped" do
        assert_equal(["id", "First Name"], schema("subset").projection { ["id", "notes", "First Name"] })
        assert_equal(["First Name"], schema("partial").projection { ["notes", "First Name"] })
      end

      it "returns nil without asking for the columns when the schema checks the columns that it does not list" do
        %w[exact equal superset].each do |fields_match|
          assert_nil schema(fields_match).projection { flunk("Asked for the columns with #{fields_match}") }, fields_match
        end
      end

      it "returns nil when no column is a field" do
        assert_nil(schema("partial").projection { %w[notes] })
      end

      it "returns nil when two columns are the same field" do
        assert_nil(schema("subset").projection { %w[id ID first_name] })
      end
    end

    describe IOStreams::Schema::Field do
      # The ways that the JSON format writes a value: with the coder of the json gem, when it uses one, see
      # `IOStreams::Tabular::Parser::Json.coder`, and without one.
      let(:json_writers) { [IOStreams::Tabular::Parser::Json.coder, nil].uniq }

      describe "#to_h" do
        it "returns the properties as they were given, with Symbol keys, also within its constraints" do
          field = field("type" => "number", "decimals" => 2, "constraints" => {"required" => true}, "title" => "Amount")

          assert_equal({name: "value", type: "number", decimals: 2, constraints: {required: true}, title: "Amount"}, field.to_h)
        end

        it "compares fields by their properties" do
          assert_equal field(type: "integer"), field("type" => "integer")
          refute_equal field(type: "integer"), field(type: "string")
          hash = {name: "value", type: "integer"}

          assert_equal "#<IOStreams::Schema::Field #{hash.inspect}>", field(type: "integer").inspect
        end
      end

      describe "string" do
        let(:string) { field(type: "string") }

        it "keeps text as it is, also text of only whitespace, which is not a missing value" do
          assert_equal " Jack ", string.cast(" Jack ")
          assert_equal "   ", string.cast("   ")
        end

        it "reads empty text as nil, a missing value, as Frictionless' default missingValues of [\"\"] does" do
          assert_nil string.cast("")
          assert_nil field.cast("")
          assert_nil string.render("", :text)
          assert_nil string.render("", :json)
        end

        it "writes a number that is not finite as Frictionless writes it, NaN, INF or -INF" do
          assert_equal "INF", string.cast(Float::INFINITY)
          assert_equal "-INF", string.cast(BigDecimal("-Infinity"))
          assert_equal "NaN", string.cast(Float::NAN)
          assert_equal "-INF", field.render(-Float::INFINITY, :text)
          assert_raises(IOStreams::Errors::InvalidValue) { field.render(BigDecimal("Infinity"), :json) }
          assert_equal "INF", IOStreams::Schema::Field.any_text(Float::INFINITY)
        end

        it "converts other values to text" do
          assert_equal "42", string.cast(42)
          assert_equal "1.5", string.cast(BigDecimal("1.5"))
          assert_equal "true", string.cast(true)
          assert_equal "name", string.cast(:name)
          assert_equal "2026-10-13", string.cast(Date.new(2026, 10, 13))
          assert_equal "2026-10-13T09:30:00Z", string.cast(Time.utc(2026, 10, 13, 9, 30))
          assert_equal "2026-10-13T09:30:00.250Z", string.cast(Time.utc(2026, 10, 13, 9, 30, 0.25r))
        end

        it "converts any other object to its text, such as an id" do
          id = Struct.new(:value) { def to_s = "id-#{value}" }.new(7)

          assert_equal "id-7", string.cast(id)
        end

        it "raises for a Hash or an Array" do
          assert_raises(IOStreams::Errors::InvalidValue) { string.cast({}) }
          assert_raises(IOStreams::Errors::InvalidValue) { string.cast([1]) }
        end
      end

      describe "integer" do
        let(:integer) { field(type: "integer") }

        it "reads text" do
          assert_equal 42, integer.cast("0042")
          assert_equal(-12, integer.cast(" -12 "))
          assert_equal 5, integer.cast("+5")
        end

        it "reads empty text as nil" do
          assert_nil integer.cast("")
          assert_nil integer.cast(nil)
        end

        it "raises for text of only whitespace, which is not a missing value, but is not an integer" do
          ["   ", "\t", " \n "].each do |text|
            error = assert_raises(IOStreams::Errors::InvalidValue, text.inspect) { integer.cast(text) }
            assert_equal "Field \"value\": #{text.inspect} is not a valid integer", error.message
          end
        end

        it "accepts numbers that are whole" do
          assert_equal 42, integer.cast(42)
          assert_equal 42, integer.cast(42.0)
          assert_equal 42, integer.cast(BigDecimal("42.00"))
        end

        it "raises for a value that is not a whole number, rather than return 0 or its leading digits" do
          ["abc", "12-", "1,234", "1.5", "0x1A", "1_000", "12.01", "1.2e1", ".0"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { integer.cast(text) }
          end
          assert_raises(IOStreams::Errors::InvalidValue) { integer.cast(1.5) }
          assert_raises(IOStreams::Errors::InvalidValue) { integer.cast(true) }
        end

        it "reads the text of a whole number with a decimal point, as a spreadsheet stores every number" do
          assert_equal 12, integer.cast("12.0")
          assert_equal(-12, integer.cast(" -12.00 "))
          assert_equal 12, integer.cast("+0012.")
          assert_equal "12", integer.render("12.0", :text)
        end

        it "names the field and the value" do
          error = assert_raises(IOStreams::Errors::InvalidValue) { integer.cast("N/A") }
          assert_equal 'Field "value": "N/A" is not a valid integer', error.message
        end

        it "renders text" do
          assert_equal "42", integer.render("0042", :text)
          assert_equal 42, integer.render("0042", :json)
          assert_equal 42, integer.render("0042", :typed)
          assert_nil integer.render(nil, :text)
        end
      end

      describe "number" do
        let(:number) { field(type: "number") }

        it "reads text as a BigDecimal" do
          assert_equal BigDecimal("12.5"), number.cast("12.50")
          assert_kind_of BigDecimal, number.cast("12.50")
          assert_equal BigDecimal("-1500"), number.cast("-1.5E3")
          assert_equal BigDecimal("0.5"), number.cast(".5")
          assert_equal BigDecimal("5"), number.cast("+5.")
        end

        it "reads a decimal point without digits after it with every version of Ruby" do
          float = field(type: "number", floatNumber: true)

          assert_equal BigDecimal("12"), number.cast("12.")
          assert_equal BigDecimal("-100"), number.cast("-1.E2")
          assert_in_delta 12.0, float.cast("000000012.")
          assert_in_delta 0.01, float.cast("1.e-2")
        end

        it "reads the numbers that are not finite" do
          assert_predicate number.cast("NaN"), :nan?
          assert_equal 1, number.cast("INF").infinite?
          assert_equal(-1, number.cast("-inf").infinite?)
        end

        it "reads Infinity and -Infinity, as Ruby and JavaScript write them, whatever their case" do
          float = field(type: "number", floatNumber: true)

          %w[Infinity INFINITY infinity].each do |text|
            assert_equal 1, number.cast(text).infinite?, text
            assert_equal Float::INFINITY, float.cast(text), text
          end
          assert_equal(-1, number.cast("-Infinity").infinite?)
          assert_equal(-Float::INFINITY, float.cast(" -infinity "))
          ["+INF", "Inf1", "Infinit", "--Infinity"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { number.cast(text) }
          end
        end

        it "writes a number that is not finite as Frictionless writes it, NaN, INF or -INF, rather than Infinity" do
          assert_equal "INF", number.render("Infinity", :text)
          assert_equal "-INF", field(type: "number", floatNumber: true).render("-Infinity", :text)
          assert_equal "-INF", number.dump(BigDecimal("-Infinity"))
        end

        it "keeps reading the text of a whole number with a decimal point as an integer, as a leniency" do
          assert_equal 12, field(type: "integer").cast("12.0")
        end

        it "returns a Float with floatNumber" do
          float = field(type: "number", floatNumber: true)

          assert_in_delta 12.5, float.cast("12.50")
          assert_kind_of Float, float.cast("12.50")
          assert_equal Float::INFINITY, float.cast("INF")
        end

        it "converts numbers" do
          assert_equal BigDecimal("12"), number.cast(12)
          assert_equal BigDecimal("1.1"), number.cast(1.1)
        end

        it "converts a Rational, keeping every digit of a decimal that ends" do
          assert_equal BigDecimal("12345678901234567.89"), number.cast(1_234_567_890_123_456_789/100r)
          assert_equal BigDecimal("-0.875"), number.cast(-7/8r)
          assert_equal BigDecimal(7), number.cast(7r)
          assert_in_delta 0.333333, number.cast(1/3r), 1e-6
          assert_in_delta 0.25, field(type: "number", floatNumber: true).cast(1/4r)
          assert_equal "0.33", field(type: "number", decimals: 2).render(1/3r, :text)
        end

        it "keeps every digit of a Rational whose decimal has more digits than bigdecimal divides to" do
          [Rational(1, 2**70), -Rational(3, 2**46), 0.1.to_r, (1 + (5/100r))**30, Rational(9_999_999_999_999_999, 2**23)].each do |rational|
            assert_equal rational, number.cast(rational).to_r, rational.inspect
          end
        end

        it "raises for a value that is not a number" do
          ["abc", "1,5", "1.2.3", "$5"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { number.cast(text) }
          end
          assert_raises(IOStreams::Errors::InvalidValue) { number.cast(true) }
        end

        it "renders text without an exponent" do
          assert_equal "12.5", number.render(BigDecimal("12.5"), :text)
          assert_equal "100000000000000000000.0", number.render(BigDecimal("1E20"), :text)
          assert_equal "NaN", number.render("NaN", :text)
          assert_equal "-INF", number.render("-INF", :text)
        end

        it "renders text with the number of decimals, rounding half up" do
          decimals = field(type: "number", decimals: 2)

          assert_equal "12.50", decimals.render("12.5", :text)
          assert_equal "2.68", decimals.render("2.675", :text)
          assert_equal "-0.13", decimals.render(-0.125, :text)
          assert_equal "13", field(type: "number", decimals: 0).render("12.5", :text)
        end

        it "rounds the number read to its decimals, as it rounds the number written, so that a record holds what is written" do
          decimals = field(type: "number", decimals: 2)
          float    = field(type: "number", floatNumber: true, decimals: 2)

          assert_equal BigDecimal("12.35"), decimals.cast("12.345")
          assert_equal BigDecimal("-0.13"), decimals.cast("-0.125")
          assert_equal BigDecimal("2.68"), decimals.cast(BigDecimal("2.675"))
          assert_equal BigDecimal("1.01"), decimals.cast(1.005)
          assert_equal BigDecimal("0.33"), decimals.cast(1/3r)
          assert_equal BigDecimal("12.5"), decimals.cast(12.5)
          # A Float is rounded as `format` writes it, 12.345, whose text ends in 5, to the even digit.
          assert_in_delta 12.34, float.cast("12.345")
          assert_equal "12.34", float.render("12.345", :text)
          assert_equal Float(float.render(2.675, :text)), float.cast(2.675)
          assert_equal decimals.render("12.345", :text), decimals.render(decimals.cast("12.345"), :text)
        end

        it "rounds to no decimals as a BigDecimal, half up, whatever the rounding mode of BigDecimal" do
          whole = field(type: "number", decimals: 0)

          assert_equal BigDecimal("3"), whole.cast("2.5")
          assert_kind_of BigDecimal, whole.cast("2.5")
          BigDecimal.save_rounding_mode do
            BigDecimal.mode(BigDecimal::ROUND_MODE, :banker)

            assert_equal BigDecimal("3"), whole.cast("2.5")
            assert_equal "3", whole.render("2.5", :text)
          end
        end

        it "rounds a Float whose text ends in 5 to the even digit, whatever its binary value, as format does" do
          assert_equal Float("2"), field(type: "number", floatNumber: true, decimals: 0).cast("2.5")
          assert_equal Float("4"), field(type: "number", floatNumber: true, decimals: 0).cast("3.5")
          assert_equal Float("0.12"), field(type: "number", floatNumber: true, decimals: 2).cast("0.125")
          # The Float 0.025 is above 0.025, and 2.675 below 2.675.
          assert_equal Float("0.02"), field(type: "number", floatNumber: true, decimals: 2).cast("0.025")
          assert_equal Float("2.68"), field(type: "number", floatNumber: true, decimals: 2).cast("2.675")
          assert_equal BigDecimal("0.13"), field(type: "number", decimals: 2).cast("0.125")
        end

        it "rounds a negative number to zero, rather than -0.0" do
          float   = field(type: "number", floatNumber: true, decimals: 2)
          decimal = field(type: "number", decimals: 2)

          # The text of -0.0 is "-0.0", for a Float and for a BigDecimal.
          [float.cast("-0.001"), decimal.cast("-0.001"), field(type: "number", decimals: 0).cast("-0.4")].each do |zero|
            assert_equal "0.0", zero.to_s, zero.inspect
          end
          assert_equal "0.00", float.render("-0.001", :text)
          assert_equal "0.00", decimal.render("-0.001", :text)
          assert_equal "0.00", JSON.generate([float.render(-0.001, :json)])[1..-2]
        end

        it "keeps a number that is not finite as it is, whatever its decimals" do
          assert_predicate field(type: "number", decimals: 2).cast("NaN"), :nan?
          assert_equal(-1, field(type: "number", decimals: 2).cast("-INF").infinite?)
        end

        it "renders a Float with the number of decimals" do
          assert_equal "12.50", field(type: "number", floatNumber: true, decimals: 2).render(12.5, :text)
        end

        it "rounds a number to its decimals as it writes its text, for a format that holds the number itself" do
          float   = field(type: "number", floatNumber: true, decimals: 2)
          whole   = field(type: "number", floatNumber: true, decimals: 0)
          decimal = field(type: "number", decimals: 2)

          [0.125, 0.375, 2.675, 1.005, 12.5, 2.5].each do |value|
            assert_equal Float(float.render(value, :text)), float.round(value), value.inspect
            assert_equal Float(whole.render(value, :text)), whole.round(value), value.inspect
            assert_equal BigDecimal(decimal.render(value, :text)), decimal.round(decimal.cast(value)), value.inspect
          end
          assert_equal 3, field(type: "number", decimals: 0).round(BigDecimal("2.5"))
          assert_same 0.125, field(type: "number", floatNumber: true).round(0.125)
        end

        it "rounds a number that is not finite to itself" do
          assert_predicate field(type: "number", floatNumber: true, decimals: 0).round(Float::NAN), :nan?
          assert_equal(-Float::INFINITY, field(type: "number", floatNumber: true, decimals: 0).round(-Float::INFINITY))
          assert_predicate field(type: "number", decimals: 2).round(BigDecimal("NaN")), :nan?
        end

        # Returns [String] the JSON that the json gem writes for the value of the field.
        def json(field, value)
          JSON.generate([field.render(value, :json)])[1..-2]
        end

        it "renders a JSON number with all of its digits" do
          long = "12345678901234567.890123"

          assert_equal long, json(number, long)
          assert_equal "12.50", json(field(type: "number", decimals: 2), "12.5")
          assert_equal "1234567890123456789.0", json(number, 1_234_567_890_123_456_789)
          assert_equal number.render(1_234_567_890_123_456_789, :text), json(number, 1_234_567_890_123_456_789)
          assert_equal BigDecimal("12.5"), number.render("12.50", :typed)
        end

        it "renders a JSON number as a JSON::Fragment, which the coder of the json gem writes as it is" do
          assert_equal JSON::Fragment.new("12.50"), field(type: "number", decimals: 2).render("12.5", :json)
        end

        it "converts a JSON::Fragment into a JsonNumber, for a writer of JSON other than the coder of the json gem" do
          assert_equal IOStreams::Schema::JsonNumber.new("12.50"), IOStreams::Schema::Field.any_json(JSON::Fragment.new("12.50"))
          # The JSON format converts each value within a Hash or an Array, which Field.any_json returns as it is.
          record = {"a" => JSON::Fragment.new("1.0")}

          assert_same record, IOStreams::Schema::Field.any_json(record)
          assert_equal({"a" => IOStreams::Schema::JsonNumber.new("1.0")}, IOStreams::Tabular::Parser::Json.json_value(record))
          assert_equal %({"a":12.50}), IOStreams::Tabular::Parser::Json.generate({"a" => JSON::Fragment.new("12.50")}, nil)
        end

        it "writes a JsonNumber as its text, as a Numeric whose as_json is itself, which ActiveSupport writes with to_json" do
          number = IOStreams::Schema::JsonNumber.new("12.50")

          assert_kind_of Numeric, number
          assert_same number, number.as_json
          assert_equal "12.50", number.to_json
          assert_equal "12.50", number.to_s
          assert_equal %({"a":12.50}), JSON.generate({"a" => number})
          assert_equal [number], [IOStreams::Schema::JsonNumber.new("12.50")]
        end

        it "renders a JSON number as the text of a Float with floatNumber and decimals, the same as CSV" do
          float = field(type: "number", floatNumber: true, decimals: 2)

          assert_kind_of Float, field(type: "number", floatNumber: true).render("12.50", :json)
          assert_equal "12.50", json(float, 12.5)
          ["12.345", 0.125, 1.005, 2.675].each do |value|
            assert_equal float.render(value, :text), json(float, value), value.inspect
          end
          assert_equal field(type: "number", floatNumber: true, decimals: 0).render(12.5, :text),
                       json(field(type: "number", floatNumber: true, decimals: 0), 12.5)
        end

        it "raises for a JSON number that is not finite, which JSON cannot hold, naming the field" do
          [number, field(type: "number", floatNumber: true), field(type: "number", decimals: 2)].each do |numbers|
            ["NaN", "INF", "-INF", Float::NAN, BigDecimal("-Infinity")].each do |value|
              error = assert_raises(IOStreams::Errors::InvalidValue, value.inspect) { numbers.render(value, :json) }
              assert_includes error.message, 'Field "value": JSON cannot hold a number that is not finite'
            end
          end

          assert_equal "INF", number.render("INF", :text)
          [Float::NAN, Float::INFINITY, BigDecimal("-Infinity")].each do |value|
            error = assert_raises(IOStreams::Errors::InvalidValue, value.inspect) { field.render(value, :json) }
            assert_includes error.message, "JSON cannot hold a number that is not finite"
          end
          assert_equal({"x" => BigDecimal("-Infinity")}, field.render({"x" => BigDecimal("-Infinity")}, :json))
        end
      end

      describe "constraints" do
        it "checks enum of every type, reading its values as the field reads its values" do
          status = field(type: "string", constraints: {enum: %w[open closed]})
          on     = field(type: "date", format: "%d/%m/%Y", constraints: {enum: ["01/02/2026", "2026-03-04"]})

          assert_equal "open", status.cast("open")
          error = assert_raises(IOStreams::Errors::InvalidValue) { status.cast("pending") }
          assert_equal 'Field "value": "pending" is not one of its enum values', error.message
          assert_equal "pending", error.value
          assert_equal 2, field(type: "integer", constraints: {enum: [1, "2"]}).cast(" 2 ")
          assert_equal Date.new(2026, 3, 4), on.cast("04/03/2026")
          assert_raises(IOStreams::Errors::InvalidValue) { on.cast("05/03/2026") }
          assert_equal BigDecimal("1.5"), field(type: "number", constraints: {enum: ["1.50"]}).cast(1.5)
          assert_nil status.cast(nil)
        end

        it "checks minimum, maximum, exclusiveMinimum and exclusiveMaximum of the types that are ordered" do
          age  = field(type: "integer", constraints: {minimum: 0, maximum: "120"})
          rate = field(type: "number", constraints: {exclusiveMinimum: 0, exclusiveMaximum: 1})
          on   = field(type: "date", constraints: {minimum: "2026-01-01"})

          assert_equal 0, age.cast("0")
          assert_equal 120, age.cast(120)
          error = assert_raises(IOStreams::Errors::InvalidValue) { age.cast("-1") }
          assert_equal 'Field "value": "-1" is less than its minimum, 0', error.message
          error = assert_raises(IOStreams::Errors::InvalidValue) { age.cast(121) }
          assert_equal 'Field "value": 121 is more than its maximum, "120"', error.message
          assert_equal BigDecimal("0.5"), rate.cast("0.5")
          error = assert_raises(IOStreams::Errors::InvalidValue) { rate.cast("0") }
          assert_equal 'Field "value": "0" is not more than its exclusiveMinimum, 0', error.message
          assert_raises(IOStreams::Errors::InvalidValue) { rate.cast("1") }
          assert_raises(IOStreams::Errors::InvalidValue) { rate.cast("NaN") }
          assert_equal Date.new(2026, 1, 1), on.cast("2026-01-01")
          assert_raises(IOStreams::Errors::InvalidValue) { on.cast(Date.new(2025, 12, 31)) }
        end

        it "compares times, datetimes and durations" do
          at    = field(type: "datetime", constraints: {maximum: "2026-10-31T23:59:59Z"})
          clock = field(type: "time", constraints: {minimum: "09:00:00", maximum: "17:00:00"})
          long  = field(type: "duration", constraints: {minimum: "PT1H"})

          assert_raises(IOStreams::Errors::InvalidValue) { at.cast("2026-11-01T00:00:00Z") }
          assert_equal Time.utc(2000, 1, 1, 9), clock.cast("09:00:00")
          assert_raises(IOStreams::Errors::InvalidValue) { clock.cast("08:59:59") }
          assert_equal "PT2H", long.cast("PT2H").iso8601
          assert_raises(IOStreams::Errors::InvalidValue) { long.cast("PT30M") }
        end

        it "checks minLength and maxLength of the characters of a string, and the items of an array or object" do
          code = field(type: "string", constraints: {minLength: 2, maxLength: 3})
          tags = field(type: "array", constraints: {maxLength: 2})

          assert_equal "ab", code.cast("ab")
          error = assert_raises(IOStreams::Errors::InvalidValue) { code.cast("a") }
          assert_equal 'Field "value": "a" has a length of 1, less than its minLength, 2', error.message
          error = assert_raises(IOStreams::Errors::InvalidValue) { code.cast("abcd") }
          assert_equal 'Field "value": "abcd" has a length of 4, more than its maxLength, 3', error.message
          assert_equal "é日本", code.cast("é日本")
          assert_equal [1, 2], tags.cast("[1,2]")
          assert_raises(IOStreams::Errors::InvalidValue) { tags.cast([1, 2, 3]) }
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "object", constraints: {minLength: 1}).cast({}) }
        end

        it "matches the whole text of a string with pattern, a Ruby regular expression" do
          zip = field(type: "string", constraints: {pattern: "\\d{5}|\\d{5}-\\d{4}"})

          assert_equal "12345", zip.cast("12345")
          assert_equal "12345-6789", zip.cast("12345-6789")
          %W[1234 123456 x12345 12345-67 12345\n].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text.inspect) { zip.cast(text) }
          end
          error = assert_raises(IOStreams::Errors::InvalidValue) { zip.cast("1234") }
          assert_equal 'Field "value": "1234" does not match its pattern, /\d{5}|\d{5}-\d{4}/', error.message
        end

        it "matches the classes of a pattern as Unicode, as XML Schema does" do
          word = field(type: "string", constraints: {pattern: "\\w+( \\w+)*"})

          assert_equal "café crème", word.cast("café crème")
          assert_equal "Zürich", word.cast("Zürich")
          assert_raises(IOStreams::Errors::InvalidValue) { word.cast("a-b") }
        end

        it "raises for text that cannot be matched with its pattern, such as text that is not valid in its encoding" do
          name = field(type: "string", constraints: {pattern: "é+"})

          error = assert_raises(IOStreams::Errors::InvalidValue) { name.cast("\xE9t\xE9".b) }
          assert_match(/cannot be matched with its pattern/, error.message)
          assert_raises(IOStreams::Errors::InvalidValue) { name.cast("\xFF\xFE") }
        end

        it "raises for a pattern that closes a group that it does not open, rather than change its anchors" do
          error = assert_raises(ArgumentError) { field(type: "string", constraints: {pattern: "a)|(b"}) }
          assert_match(/constraints pattern is not a valid regular expression/, error.message)
        end

        it "checks each value written too" do
          age = field(type: "integer", constraints: {minimum: 0})

          assert_equal "5", age.render(5, :text)
          assert_raises(IOStreams::Errors::InvalidValue) { age.render(-5, :text) }
          assert_raises(IOStreams::Errors::InvalidValue) { age.render(-5, :typed) }
        end

        it "raises for a constraint that does not apply to the type of the field" do
          [
            {type: "string", constraints: {minimum: "a"}}, {type: "boolean", constraints: {maximum: true}},
            {type: "integer", constraints: {minLength: 1}}, {type: "integer", constraints: {pattern: "\\d+"}},
            {type: "any", constraints: {maxLength: 1}}
          ].each do |properties|
            assert_raises(ArgumentError, properties.inspect) { field(**properties) }
          end
          error = assert_raises(ArgumentError) { field(type: "integer", constraints: {pattern: "1"}) }
          assert_equal 'Field "value": the constraint "pattern" only applies to a field of type string, not integer', error.message
        end

        it "checks a value that the field read, such as a number rounded to its decimals, and no missing value" do
          rounded = field(type: "number", decimals: 0, constraints: {maximum: 100})
          missing = IOStreams::Schema.new(
            missingValues: ["NA"],
            fields:        [{name: "value", type: "integer", constraints: {minimum: 1, enum: [1, 2]}}]
          ).fields.first

          assert_equal BigDecimal("100"), rounded.cast("100.4")
          assert_nil missing.cast("NA")
          assert_nil missing.cast(nil)
          assert_raises(IOStreams::Errors::InvalidValue) { missing.cast("0") }
        end

        it "compares integers and strings with enum as the keys of a Hash, and other types with ==" do
          assert_equal 2, field(type: "integer", constraints: {enum: [1, 2]}).cast("2")
          assert_equal BigDecimal(1), field(type: "number", constraints: {enum: [1.0]}).cast("1")
          assert_equal "b", field(type: "string", categories: %w[a b]).cast("b")
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "string", constraints: {enum: %w[a b]}).cast("c") }
        end

        it "says that a value that cannot be compared with a bound, such as NaN, cannot be" do
          error = assert_raises(IOStreams::Errors::InvalidValue) { field(type: "number", constraints: {minimum: 0}).cast("NaN") }
          assert_equal 'Field "value": "NaN" cannot be compared with its minimum, 0', error.message
        end

        it "keeps a value of a constraint that JSON does not hold as the text that the field writes, which reads back" do
          date   = field(type: "date", constraints: {minimum: Date.new(2026, 1, 1), enum: [Date.new(2026, 1, 2)]})
          number = field(type: "number", constraints: {maximum: BigDecimal("1.5")})

          assert_equal({minimum: "2026-01-01", enum: ["2026-01-02"]}, date.to_h[:constraints])
          assert_equal({maximum: "1.5"}, number.to_h[:constraints])
          error = assert_raises(IOStreams::Errors::InvalidValue) { number.cast("2") }
          assert_equal 'Field "value": "2" is more than its maximum, "1.5"', error.message
          schema = IOStreams::Schema.new(fields: [date.to_h, number.to_h.merge(name: "pay")])

          assert_equal schema, IOStreams::Schema.new(JSON.parse(JSON.generate(schema.to_h)))
        end

        it "raises for bounds that leave no value, or that are NaN" do
          [
            {minimum: 5, maximum: 4}, {minimum: 5, exclusiveMaximum: 5}, {exclusiveMinimum: 5, maximum: 5},
            {exclusiveMinimum: 5, exclusiveMaximum: 5}, {minimum: "NaN"}, {maximum: "nan"}
          ].each do |constraints|
            assert_raises(ArgumentError, constraints.inspect) { field(type: "number", constraints: constraints) }
          end
          assert_equal BigDecimal(5), field(type: "number", constraints: {minimum: 5, maximum: 5}).cast("5")
          error = assert_raises(ArgumentError) { field(type: "integer", constraints: {minimum: 5, maximum: 4}) }
          assert_equal 'Field "value": constraints minimum, 5, leaves no value up to its maximum, 4', error.message
        end

        it "raises for a value of a constraint that is not valid, or not a value of the field" do
          [
            {type: "integer", constraints: {minimum: "x"}}, {type: "integer", constraints: {minimum: 1.5}},
            {type: "date", constraints: {maximum: "31/12/2026"}}, {type: "string", constraints: {minLength: -1}},
            {type: "string", constraints: {maxLength: "3"}}, {type: "string", constraints: {pattern: "("}},
            {type: "string", constraints: {pattern: 5}}, {type: "string", constraints: {enum: []}},
            {type: "string", constraints: {enum: "a"}}, {type: "integer", constraints: {enum: [1, "x"]}},
            {type: "integer", constraints: {minimum: nil}}, {type: "integer", constraints: {minimum: ""}}
          ].each do |properties|
            assert_raises(ArgumentError, properties.inspect) { field(**properties) }
          end
          error = assert_raises(ArgumentError) { field(type: "integer", constraints: {minimum: "x"}) }
          assert_equal 'Field "value": constraints minimum must be a value of the field: Field "value": "x" is not a valid integer',
                       error.message
        end

        it "keeps raising for jsonSchema, which is not supported" do
          error = assert_raises(ArgumentError) { field(type: "object", constraints: {jsonSchema: {type: "object"}}) }
          assert_equal 'Field "value": the constraint "jsonSchema" is not supported', error.message
        end

        it "names the record that a value not following a constraint is in, when reading" do
          schema = IOStreams::Schema.new(fields: [{name: "age", type: "integer", constraints: {minimum: 0}}])
          rows   = []
          error  = assert_raises(IOStreams::Errors::InvalidValue) do
            IOStreams.stream(StringIO.new("age\n5\n-1\n")).file_name("a.csv").schema(schema).each(:hash) { |row| rows << row }
          end

          assert_equal 'Field "age": "-1" is less than its minimum, 0', error.reason
          assert_equal 2, error.record_number
          assert_equal [{"age" => 5}], rows
        end
      end

      describe "categories" do
        it "reads a value of a string or integer field only when it is one of its categories" do
          size = field(type: "string", categories: %w[S M L])
          code = field(type: "integer", categories: [{value: 1, label: "One"}, {"value" => "2", "label" => "Two"}])

          assert_equal "M", size.cast("M")
          error = assert_raises(IOStreams::Errors::InvalidValue) { size.cast("XL") }
          assert_equal 'Field "value": "XL" is not one of its categories', error.message
          assert_equal 2, code.cast("2")
          assert_raises(IOStreams::Errors::InvalidValue) { code.cast("3") }
          assert_nil size.cast("")
        end

        it "accepts categoriesOrdered, which does not change how values are read" do
          size = field(type: "string", categories: %w[S M L], categoriesOrdered: true)

          assert_equal "L", size.cast("L")
          assert_equal({name: "value", type: "string", categories: %w[S M L], categoriesOrdered: true}, size.to_h)
        end

        it "raises for an enum value that is not one of its categories" do
          error = assert_raises(ArgumentError) { field(type: "string", categories: %w[S M], constraints: {enum: %w[M L]}) }
          assert_equal 'Field "value": the enum value "L" is not one of its categories', error.message
          assert_equal "S", field(type: "string", categories: %w[S M], constraints: {enum: %w[S]}).cast("S")
        end

        it "raises for categories that are not valid, or of another type of field" do
          [
            {type: "string", categories: "S"}, {type: "string", categories: []}, {type: "integer", categories: ["x"]},
            {type: "string", categories: [{label: "x"}]}, {type: "string", categories: [{value: "x", label: 1}]},
            {type: "string", categories: [{value: "x", code: 1}]}, {type: "number", categories: [1]},
            {type: "string", categories: %w[a], categoriesOrdered: "yes"}, {type: "date", categoriesOrdered: true},
            {type: "string", categories: %w[a b a]}, {type: "integer", categories: [1, {value: 1, label: "One"}]},
            {type: "integer", categories: [{value: 1, label: "One"}, {value: 2, label: "One"}]},
            {type: "string", categories: [{value: "a", label: nil}]}, {type: "string", categoriesOrdered: true}
          ].each do |properties|
            assert_raises(ArgumentError, properties.inspect) { field(**properties) }
          end
        end
      end

      describe "missingValues" do
        # Returns [IOStreams::Schema::Field] the field of a schema of the supplied properties.
        def schema_field(schema = {}, **properties)
          IOStreams::Schema.new(fields: [{name: "value", **properties}], **schema).fields.first
        end

        it "reads text that is exactly one of the missing values of the schema as nil, in every type" do
          %w[any string integer number boolean date datetime time object array].each do |type|
            missing = schema_field({missingValues: ["NA", "-"]}, type: type)

            assert_nil missing.cast("NA"), type
            assert_nil missing.cast("-"), type
          end
        end

        it "compares the text as it is read, before its whitespace is removed, and keeps text that is not missing" do
          missing = schema_field({missingValues: ["NA"]}, type: "integer")

          assert_raises(IOStreams::Errors::InvalidValue) { missing.cast(" NA ") }
          assert_raises(IOStreams::Errors::InvalidValue) { missing.cast("na") }
          assert_equal "na", schema_field({missingValues: ["NA"]}, type: "string").cast("na")
        end

        it "replaces the empty text of the default, so that empty text is a value, or not one of the type" do
          assert_equal "", schema_field({missingValues: ["NA"]}, type: "string").cast("")
          assert_equal "", schema_field({missingValues: []}).cast("")
          error = assert_raises(IOStreams::Errors::InvalidValue) { schema_field({missingValues: ["NA"]}, type: "integer").cast("") }
          assert_equal 'Field "value": "" is not a valid integer', error.message
        end

        it "replaces those of the schema with those of the field, rather than add them" do
          missing = schema_field({missingValues: ["NA"]}, type: "integer", missingValues: ["-99"])

          assert_nil missing.cast("-99")
          assert_raises(IOStreams::Errors::InvalidValue) { missing.cast("NA") }
          assert_nil field(type: "integer", missingValues: ["", "N/A"]).cast("N/A")
          assert_nil field(type: "integer", missingValues: ["", "N/A"]).cast("")
        end

        it "takes objects of a value and a label, which only describes it to people" do
          missing = schema_field({missingValues: [{value: "-99", label: "Refused"}, {"value" => "-98"}]}, type: "integer")

          assert_nil missing.cast("-99")
          assert_nil missing.cast("-98")
          assert_equal(-97, missing.cast("-97"))
        end

        it "never compares a value that is not text, such as a number of JSON" do
          missing = schema_field({missingValues: ["-99", "0"]}, type: "integer")

          assert_equal(-99, missing.cast(-99))
          assert_equal 0, missing.cast(0)
        end

        it "raises for a required field, as it does for nil" do
          required = schema_field({missingValues: ["NA"]}, type: "integer", constraints: {required: true})

          error = assert_raises(IOStreams::Errors::InvalidValue) { required.cast("NA") }
          assert_equal 'Field "value" is required, but has no value', error.message
          assert_equal "NA", error.value
        end

        it "writes nil as the first missing value of the field in text, as frictionless-py does, and nil otherwise" do
          integer = schema_field({missingValues: ["NA", "-"]}, type: "integer")

          assert_equal "NA", integer.render(nil, :text)
          assert_equal "NA", schema_field({missingValues: ["NA"]}, type: "string").render("NA", :text)
          assert_equal "-99", schema_field({missingValues: ["NA"]}, type: "integer", missingValues: ["-99"]).render(nil, :text)
          assert_nil integer.render(nil, :json)
          assert_nil integer.render(nil, :typed)
          assert_nil schema_field({missingValues: ["", "NA"]}, type: "integer").render(nil, :text)
          assert_nil field(type: "integer").render(nil, :text)
        end

        it "raises for nil written as text without missing values, which no text would read back as, and not otherwise" do
          none  = schema_field({missingValues: []}, type: "integer")
          error = assert_raises(IOStreams::Errors::InvalidValue) { none.render(nil, :text) }

          assert_equal "value", error.field
          assert_nil none.render(nil, :json)
          assert_nil none.render(nil, :typed)
          assert_nil none.render(nil, :scalar)
          assert_equal "", schema_field({missingValues: []}, type: "string").render("", :text)
        end

        it "converts a value that a schema already read, or a store returned, without comparing it with them" do
          number = schema_field({missingValues: ["", "-99", "0"]}, type: "number")

          assert_nil number.cast("-99")
          assert_equal BigDecimal("-99"), number.cast_typed(BigDecimal("-99"))
          assert_equal BigDecimal("-99"), number.load(number.dump(BigDecimal("-99")))
          assert_equal BigDecimal("0"), number.load(number.dump(BigDecimal("0")))
          # Text that a typed source holds, such as a query, is text, which is compared.
          assert_nil number.restore("0")
          assert_equal "NA", schema_field({missingValues: ["NA"]}, type: "string").cast_typed("NA")
          assert_nil number.cast_typed(nil)
        end

        it "keeps them as they were given, each object with Symbol keys, and compares fields by them" do
          schema = IOStreams::Schema.new(missingValues: [{value: "-99", label: "Refused"}, {"value" => "-98"}],
                                         fields:        [{name: "a", missingValues: [{"value" => "y", "label" => "Y"}]}])

          assert_equal({missingValues: [{value: "-99", label: "Refused"}, {value: "-98"}],
                        fields:        [{name: "a", missingValues: [{value: "y", label: "Y"}]}]}, schema.to_h)
          assert_equal schema, IOStreams::Schema.new(JSON.parse(JSON.generate(schema.to_h)))
          refute_equal schema_field({missingValues: ["NA"]}), schema_field({missingValues: ["-"]})
          assert_equal schema_field({missingValues: ["NA"]}), schema_field({missingValues: ["NA"]})
          assert_equal schema_field, field
        end

        it "leaves them to the schema of the file, which reads its own text" do
          schema = IOStreams::Schema.new(missingValues: ["NA"], fields: [{name: "a", type: "integer", missingValues: ["x"]}])

          assert_equal({fields: [{name: "a", type: "integer"}]}, schema.without_text.to_h)
        end

        it "raises for missing values that are not an Array of text, or of objects of a text value and label" do
          [{missingValues: "NA"}, {missingValues: [1]}, {missingValues: [nil]}, {missingValues: [{label: "x"}]},
           {missingValues: [{value: 1}]}, {missingValues: [{value: "x", label: 2}]}, {missingValues: [{value: "x", code: 1}]}].each do |schema|
            assert_raises(ArgumentError, schema.inspect) { IOStreams::Schema.new(fields: [{name: "a"}], **schema) }
            assert_raises(ArgumentError, schema.inspect) { field(**schema) }
          end
          error = assert_raises(ArgumentError) { field(missingValues: "NA") }
          assert_equal 'Field "value": missingValues must be an Array of text, or of objects with a value: "NA"', error.message
        end

        it "raises for missing values that mix text and objects, as Frictionless requires one or the other" do
          # The inspect of the list, which Ruby 3.3 writes as `{:value=>"-99"}`, and Ruby 3.4 as `{value: "-99"}`.
          error = assert_raises(ArgumentError) { field(missingValues: ["NA", {value: "-99"}]) }
          assert_equal 'Field "value": missingValues must be all text, or all objects with a value, not both: ' \
                       "#{['NA', {value: '-99'}].inspect}", error.message
          error = assert_raises(ArgumentError) { IOStreams::Schema.new(missingValues: [{value: "-99"}, ""], fields: [{name: "a"}]) }
          assert_equal "The schema missingValues must be all text, or all objects with a value, not both: " \
                       "#{[{value: '-99'}, ''].inspect}", error.message
        end

        it "raises for missing values that repeat a text, a value or a label, which Frictionless requires to be unique" do
          error = assert_raises(ArgumentError) { field(missingValues: ["", "NA", "-", "NA"]) }
          assert_equal 'Field "value": missingValues must not repeat a value: "NA"', error.message
          error = assert_raises(ArgumentError) { IOStreams::Schema.new(missingValues: ["", ""], fields: [{name: "a"}]) }
          assert_equal 'The schema missingValues must not repeat a value: ""', error.message
          error = assert_raises(ArgumentError) { field(missingValues: [{value: "-99", label: "Refused"}, {"value" => "-99"}]) }
          assert_equal 'Field "value": missingValues must not repeat a value: "-99"', error.message
          error = assert_raises(ArgumentError) do
            field(missingValues: [{value: "-99", label: "Refused"}, {"value" => "-98", "label" => "Refused"}])
          end
          assert_equal 'Field "value": missingValues must not repeat a label: "Refused"', error.message
          assert_raises(ArgumentError) { Class.new(IOStreams::Contract) { missing_values %w[NA NA] } }

          unlabeled = field(type: "integer", missingValues: [{value: "-99"}, {value: "-98"}, {value: "-97", label: "Refused"}])

          assert_nil unlabeled.cast("-98")
        end
      end

      describe "groupChar, decimalChar and bareNumber" do
        it "removes the groupChar of a number or an integer wherever it is, and writes it between each 3 digits" do
          grouped = field(type: "number", groupChar: ",")
          integer = field(type: "integer", groupChar: " ")

          assert_equal BigDecimal("1234567.5"), grouped.cast("1,234,567.5")
          assert_equal BigDecimal("1234"), grouped.cast("12,34")
          assert_equal "-1,234,567.50", field(type: "number", groupChar: ",", decimals: 2).render("-1234567.5", :text)
          assert_equal "123.0", grouped.render("123", :text)
          assert_equal 1_234_567, integer.cast("1 234 567")
          assert_equal "1 234 567", integer.render(1_234_567, :text)
          assert_equal "-1 234", integer.render(-1234, :text)
        end

        it "reads and writes the groupChar \".\" of an integer, which has no decimal point" do
          integer = field(type: "integer", groupChar: ".")

          assert_equal 1_234_567, integer.cast("1.234.567")
          assert_equal "1.234.567", integer.render(1_234_567, :text)
          assert_equal 12, field(type: "integer", groupChar: ",").cast("12.0")
        end

        it "reads and writes the decimalChar of a number, and raises for a point that is not it" do
          european = field(type: "number", groupChar: ".", decimalChar: ",")
          comma    = field(type: "number", decimalChar: ",")

          assert_equal BigDecimal("1234.5"), european.cast("1.234,50")
          assert_equal "1.234.567,5", european.render(BigDecimal("1234567.5"), :text)
          assert_equal BigDecimal("12.5"), comma.cast("12,5")
          assert_raises(IOStreams::Errors::InvalidValue) { comma.cast("12.5") }
          assert_equal "12,5", comma.render(12.5, :text)
          assert_equal "NaN", comma.render("NaN", :text)
          assert_equal "12345678901234567890,5", comma.render(BigDecimal("12345678901234567890.5"), :text)
        end

        it "writes the plain number to JSON, which has neither a groupChar nor a decimalChar" do
          european = field(type: "number", groupChar: ".", decimalChar: ",", decimals: 2)

          assert_equal JSON::Fragment.new("1234.50"), european.render("1.234,5", :json)
          assert_equal 1234, field(type: "integer", groupChar: ",").render("1,234", :json)
          assert_equal "1234.50", european.dump(european.cast("1.234,5"))
        end

        it "reads the plain number that #dump writes, without its groupChar and decimalChar, as a slice stores it" do
          european = field(type: "number", groupChar: ".", decimalChar: ",")
          grouped  = field(type: "number", groupChar: ",", bareNumber: false)

          assert_equal BigDecimal("1234.5"), european.load(european.dump(european.cast("1.234,5")))
          assert_equal BigDecimal("-1234.5"), grouped.load(grouped.dump(grouped.cast("($1,234.50)")))
          assert_predicate european.load(european.dump(BigDecimal("Infinity"))), :infinite?
          assert_raises(IOStreams::Errors::InvalidValue) { european.load("1.234,5") }
        end

        it "reads the text of a cell as the default text of its type first, then in the form of the field" do
          european = field(type: "number", groupChar: ".", decimalChar: ",", missingValues: ["NA"])
          count    = field(type: "integer", groupChar: ".")
          paid     = field(type: "date", format: "%d/%m/%Y")
          at       = field(type: "datetime", format: "%d/%m/%Y %H:%M", timeZone: "America/New_York")
          done     = field(type: "boolean", trueValues: ["Y"], falseValues: ["N"])

          assert_equal BigDecimal("1234.5"), european.parse_cell_text("1234.5", :text)
          assert_equal BigDecimal("1234.5"), european.parse_cell_text("1.234,5", :text)
          assert_equal BigDecimal("1.234"), european.parse_cell_text("1.234", :text)
          assert_nil european.parse_cell_text("NA", :text)
          assert_equal BigDecimal("12.5"), european.parse_cell_text(12.5, :scalar)
          assert_equal 1234, count.parse_cell_text("1234.0", :text)
          assert_equal 1234, count.parse_cell_text("1.234", :text)
          assert_equal Date.new(2026, 7, 1), paid.parse_cell_text("2026-07-01", :text)
          assert_equal Date.new(2026, 7, 1), paid.parse_cell_text("01/07/2026", :text)
          assert_equal Time.utc(2026, 7, 1, 13, 30), at.parse_cell_text("2026-07-01T09:30:00", :text)
          assert_equal Time.utc(2026, 7, 1, 13, 30), at.parse_cell_text("01/07/2026 09:30", :text)
          assert done.parse_cell_text("true", :text)
          refute done.parse_cell_text("N", :text)
        end

        it "raises for the text of a cell that is neither the default text of its type nor in the form of the field" do
          paid  = field(type: "date", format: "%d/%m/%Y")
          error = assert_raises(IOStreams::Errors::InvalidValue) { paid.parse_cell_text("2026-02-30", :text) }

          assert_equal "2026-02-30", error.value
          assert_raises(IOStreams::Errors::InvalidValue) do
            field(type: "boolean", trueValues: ["Y"], falseValues: ["N"]).parse_cell_text("yes", :text)
          end
        end

        it "reads a number of a format that holds numbers, such as JSON, as it is" do
          assert_equal BigDecimal("1234.5"), field(type: "number", decimalChar: ",").cast(1234.5)
          assert_equal 12, field(type: "integer", groupChar: ",", bareNumber: false).cast(12)
        end

        it "removes the text before and after the number with bareNumber: false, keeping its sign" do
          number = field(type: "number", bareNumber: false)

          {
            "95%" => "95", "$12.50" => "12.5", "12abc" => "12", "EUR 95" => "95", "€ 1.5" => "1.5", "1e3 kg" => "1000",
            "-$12.50" => "-12.5", "$-12" => "-12", "USD -12" => "-12", " 12 " => "12", "Rs. 50" => "50", ".5%" => "0.5",
            "Rs.500" => "500", "No.5" => "5", "$.50" => "0.5", "-.5" => "-0.5", "95% (est.)" => "95"
          }.each_pair do |text, value|
            assert_equal BigDecimal(value), number.cast(text), text
          end
          assert_equal 95, field(type: "integer", bareNumber: false).cast("95%")
          assert_equal 12, field(type: "integer", bareNumber: false).cast("$12.00")
        end

        it "reads parentheses around the number as a negative number with bareNumber: false, as accountants write it" do
          number = field(type: "number", bareNumber: false, groupChar: ",")

          assert_equal BigDecimal("-12.5"), number.cast("(12.50)")
          assert_equal BigDecimal("-1234.5"), number.cast("($1,234.50)")
          assert_equal(-7, field(type: "integer", bareNumber: false).cast("(7)"))
        end

        it "raises with bareNumber: false for text without a number, digits around it, or a sign twice" do
          number = field(type: "number", bareNumber: false)

          ["N/A", "abc", "12abc3", "1-2", "--12", "(-12)", "(-$12)", "+-12", "$", "()", "12-", "12 -", "(12.50", "12.50)",
           "$(12)", "12) (", "(12.50) (est."].each do |text|
            error = assert_raises(IOStreams::Errors::InvalidValue, text) { number.cast(text) }
            assert_equal "Field \"value\": #{text.inspect} is not a valid number", error.message
          end
        end

        it "finds the number with bareNumber: false before it checks the decimal point of its decimalChar" do
          comma    = field(type: "number", bareNumber: false, decimalChar: ",")
          european = field(type: "number", bareNumber: false, decimalChar: ",", groupChar: ".")

          assert_equal BigDecimal("12.5"), comma.cast("ca. 12,50")
          assert_equal BigDecimal("12.5"), comma.cast("12,50 Mio.")
          assert_equal BigDecimal("1234.5"), european.cast("ca. 1.234,50 EUR")
          assert_raises(IOStreams::Errors::InvalidValue) { comma.cast("12.50 EUR") }
        end

        it "reads the numbers that are not finite with bareNumber: false" do
          assert_equal 1, field(type: "number", bareNumber: false).cast("INF").infinite?
        end

        it "raises without bareNumber: false for text around the number, as it does without these properties" do
          ["$12.50", "95%", "(12.50)"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { field(type: "number", bareNumber: true).cast(text) }
          end
        end

        it "writes the number alone with bareNumber: false" do
          assert_equal "-12.5", field(type: "number", bareNumber: false).render(BigDecimal("-12.5"), :text)
        end

        it "raises for a property that is not valid, or does not apply to the type" do
          [
            {type: "number", groupChar: ",", decimalChar: ","}, {type: "number", groupChar: ""}, {type: "number", groupChar: "1"},
            {type: "number", decimalChar: "-"}, {type: "number", groupChar: 1}, {type: "number", bareNumber: "no"},
            {type: "integer", decimalChar: ","}, {type: "string", groupChar: ","}, {type: "date", bareNumber: false},
            {type: "number", groupChar: "e"}, {type: "number", decimalChar: "E"}, {type: "number", groupChar: "("},
            {type: "integer", groupChar: ")"}, {type: "number", groupChar: "."}
          ].each do |properties|
            assert_raises(ArgumentError, properties.inspect) { field(**properties) }
          end
        end

        it "keeps them as they were given, and leaves them to the schema of the file, which writes its own text" do
          descriptor = {name: "pay", type: "number", groupChar: ",", decimalChar: ".", bareNumber: false}
          schema     = IOStreams::Schema.new(fields: [descriptor])

          assert_equal descriptor, schema.fields.first.to_h
          assert_equal({name: "pay", type: "number"}, schema.without_text.fields.first.to_h)
        end
      end

      describe "boolean" do
        let(:boolean) { field(type: "boolean") }

        it "reads the default true and false values" do
          %w[true True TRUE 1].each { |text| assert boolean.cast(text), "#{text} is true" }
          %w[false False FALSE 0].each { |text| refute boolean.cast(text), "#{text} is false" }
          assert boolean.cast(true)
          assert_nil boolean.cast("")
        end

        it "raises for other values" do
          ["yes", "t", 2, -1, 0.5, Float::NAN, BigDecimal("2"), 1r, :yes].each do |value|
            assert_raises(IOStreams::Errors::InvalidValue, value.inspect) { boolean.cast(value) }
          end
        end

        it "reads the number 1 as true and 0 as false, such as of JSON, a spreadsheet, a Parquet file or a query" do
          [1, 1.0, BigDecimal("1"), BigDecimal("1.00")].each { |value| assert_same true, boolean.cast(value), value.inspect }
          [0, 0.0, -0.0, BigDecimal("0")].each { |value| assert_same false, boolean.cast(value), value.inspect }
          yes_no = field(type: "boolean", trueValues: %w[Y], falseValues: %w[N])

          assert_same true, yes_no.cast(1)
          assert_equal "N", yes_no.render(0, :text)
        end

        it "reads and writes the values that are set" do
          yes_no = field(type: "boolean", trueValues: %w[Y y], falseValues: ["N"])

          assert yes_no.cast("y")
          refute yes_no.cast("N")
          assert_raises(IOStreams::Errors::InvalidValue) { yes_no.cast("true") }
          assert_equal "Y", yes_no.render(true, :text)
          assert_equal "N", yes_no.render(false, :text)
          assert yes_no.render("Y", :json)
        end
      end

      describe "date" do
        let(:date) { field(type: "date") }

        it "reads ISO 8601" do
          assert_equal Date.new(2026, 10, 13), date.cast("2026-10-13")
        end

        it "raises for another form, or a date that does not exist" do
          ["13/10/2026", "2026-1-3", "2026-02-30", "2026-10-13x"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { date.cast(text) }
          end
        end

        it "converts a Time or DateTime at midnight, by its own clock, as a spreadsheet's date format reads it" do
          assert_equal Date.new(2026, 10, 13), date.cast(DateTime.new(2026, 10, 13))
          assert_equal Date.new(2026, 10, 13), date.cast(Time.new(2026, 10, 13, 0, 0, 0, "-05:00"))
          assert_equal Date.new(2026, 10, 13), date.cast(Time.utc(2026, 10, 13))
        end

        it "raises for a Time or DateTime that is not midnight, rather than lose its time of day" do
          assert_raises(IOStreams::Errors::InvalidValue) { date.cast(DateTime.new(2026, 10, 13, 9, 30)) }
          assert_raises(IOStreams::Errors::InvalidValue) { date.cast(Time.new(2026, 10, 13, 9, 30)) }
          assert_raises(IOStreams::Errors::InvalidValue) { date.cast(Time.utc(2026, 10, 13, 0, 0, 0.5r)) }
        end

        it "writes a Time only at midnight, as it reads one" do
          output = StringIO.new
          IOStreams.stream(output).file_name("dates.csv").schema(fields: [{name: "on", type: "date"}]).writer(:hash) do |io|
            io << {"on" => Time.utc(2026, 10, 13)}
          end

          assert_equal "on\n2026-10-13\n", output.string
          assert_raises(IOStreams::Errors::InvalidValue) do
            IOStreams.stream(StringIO.new).file_name("dates.csv").schema(fields: [{name: "on", type: "date"}]).writer(:hash) do |io|
              io << {"on" => Time.utc(2026, 10, 13, 9, 30)}
            end
          end
        end

        it "reads and writes the format" do
          pattern = field(type: "date", format: "%d/%m/%Y")

          assert_equal Date.new(2026, 10, 13), pattern.cast("13/10/2026")
          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("13/10/2026 extra") }
          assert_equal "13/10/2026", pattern.render(Date.new(2026, 10, 13), :text)
          assert_equal "13/10/2026", pattern.render(Date.new(2026, 10, 13), :json)
        end

        it "raises for a time in its format that is not on a clock, the hour 24 or a leap second, as Python's strptime does" do
          pattern = field(type: "date", format: "%Y-%m-%d %H:%M:%S")

          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("2026-10-13 24:00:00") }
          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("2026-10-13 23:59:60") }
          assert_equal Date.new(2026, 10, 13), pattern.cast("2026-10-13 23:59:59")
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "time", format: "%H:%M:%S").cast("23:59:60") }
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "time", format: "%H:%M").cast("24:00") }
        end

        it "reads exactly 4 digits of a year with %Y, as Python's strptime does, rather than the year 26 of 2 digits" do
          pattern = field(type: "date", format: "%d/%m/%Y")

          ["31/10/26", "31/10/026", "31/10/20260", "31/10/+2026", "31/10/-2026"].each do |text|
            error = assert_raises(IOStreams::Errors::InvalidValue, text) { pattern.cast(text) }
            assert_equal "Field \"value\": #{text.inspect} is not a valid date", error.message
          end
          assert_equal Date.new(26, 10, 31), pattern.cast("31/10/0026")
          assert_equal "31/10/0026", pattern.render(Date.new(26, 10, 31), :text)
          assert_equal Date.new(2026, 10, 31), field(type: "date", format: "%d/%m/%y").cast("31/10/26")
        end

        it "reads 4 digits of a year with %Y that digits follow, as the start of a date without separators" do
          pattern = field(type: "date", format: "%Y%m%d")

          assert_equal Date.new(2026, 10, 13), pattern.cast("20261013")
          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("261013") }
          assert_equal Date.new(2026, 10, 13), field(type: "date", format: "%d %m %Y").cast("13 10 2026")
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "date", format: "%d %m %Y").cast("13 10 26") }
        end

        it "reads exactly 2 digits for %y, as Python's strptime does" do
          pattern = field(type: "date", format: "%d/%m/%y")

          assert_equal Date.new(2026, 10, 31), pattern.cast("31/10/26")
          assert_equal Date.new(2005, 2, 1), pattern.cast("1/2/05")
          ["1/2/5", "1/2/005", "1/2/2005"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { pattern.cast(text) }
          end
          assert_equal Date.new(2026, 10, 31), field(type: "date", format: "%y%m%d").cast("261031")
        end

        it "reads exactly 4 digits for %G, the year of an ISO 8601 week" do
          pattern = field(type: "date", format: "%G-W%V-%u")

          assert_equal Date.new(2026, 10, 31), pattern.cast("2026-W44-6")
          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("26-W44-6") }
        end

        it "checks the digits of the year of a directive that reads several, and of one with a modifier" do
          assert_equal Date.new(2026, 10, 31), field(type: "date", format: "%F").cast("2026-10-31")
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "date", format: "%F").cast("26-10-31") }
          assert_equal Date.new(2026, 10, 31), field(type: "date", format: "%D").cast("10/31/26")
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "date", format: "%D").cast("10/31/6") }
          assert_equal Date.new(2026, 10, 31), field(type: "date", format: "%x").cast("10/31/26")
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "date", format: "%x").cast("10/31/2026") }
          assert_equal Date.new(2026, 10, 31), field(type: "date", format: "%v").cast("31-Oct-2026")
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "date", format: "%v").cast("31-Oct-26") }
          assert_equal Date.new(2026, 10, 31), field(type: "date", format: "%EY-%m-%d").cast("2026-10-31")
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "date", format: "%EY-%m-%d").cast("26-10-31") }
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "date", format: "%d/%m/%Ey").cast("31/10/6") }
          assert_equal "2026-10-31", field(type: "date", format: "%F").render(Date.new(2026, 10, 31), :text)
        end

        it "reads fmt:default as the default form, as frictionless-py does" do
          pattern = field(type: "date", format: "fmt:default")

          assert_equal Date.new(2026, 10, 31), pattern.cast("2026-10-31")
          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("31/10/2026") }
          assert_equal "2026-10-31", pattern.render(Date.new(2026, 10, 31), :text)
          assert_equal Time.utc(2026, 10, 31, 9, 30), field(type: "datetime", format: "fmt:default").cast("2026-10-31T09:30:00Z")
        end

        it "takes a %% as a percent sign, rather than a directive" do
          pattern = field(type: "date", format: "%%Y %Y")

          assert_equal Date.new(2026, 1, 1), pattern.cast("%Y 2026")
          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("%Y 26") }
          assert_equal "%Y 2026", pattern.render(Date.new(2026, 10, 31), :text)
        end

        it "takes %%f as a percent sign followed by f, rather than microseconds" do
          pattern = field(type: "date", format: "%%f %Y")

          assert_equal Date.new(2026, 1, 1), pattern.cast("%f 2026")
          assert_equal "%f 2026", pattern.render(Date.new(2026, 10, 31), :text)
        end

        it "removes the prefix fmt: of a format, the spelling of Data Package v0, and keeps the format as it was given" do
          pattern = field(type: "date", format: "fmt:%d/%m/%Y")

          assert_equal Date.new(2026, 10, 13), pattern.cast("13/10/2026")
          assert_equal "13/10/2026", pattern.render(Date.new(2026, 10, 13), :text)
          assert_equal "fmt:%d/%m/%Y", pattern.to_h[:format]
          assert_raises(ArgumentError) { field(type: "date", format: "fmt:") }
          assert_raises(ArgumentError) { field(type: "date", format: "fmt:dd/mm/yyyy") }
        end

        it "renders ISO 8601" do
          assert_equal "2026-10-13", date.render(Date.new(2026, 10, 13), :text)
        end
      end

      describe "datetime" do
        let(:datetime) { field(type: "datetime") }

        it "reads ISO 8601" do
          assert_equal Time.utc(2026, 10, 13, 9, 30), datetime.cast("2026-10-13T09:30:00Z")
          assert_equal Time.utc(2026, 10, 13, 14, 30, 0.3r), datetime.cast("2026-10-13T09:30:00.300-05:00")
          assert_equal(-18_000, datetime.cast("2026-10-13T09:30:00.300-05:00").utc_offset)
        end

        it "reads text without an offset from UTC as UTC, rather than in the time zone of the process" do
          original  = ENV.fetch("TZ", nil)
          ENV["TZ"] = "America/New_York"
          pattern   = field(type: "datetime", format: "%Y-%m-%d %H:%M")

          [datetime.cast("2026-10-13T09:30:00"), pattern.cast("2026-10-13 09:30"), field(type: "datetime", format: "%s").cast("1791883800")].each do |time|
            assert_equal Time.utc(2026, 10, 13, 9, 30), time
            assert_predicate time, :utc?
          end
          assert_equal Time.utc(2026, 10, 13, 9, 30, 0.25r), datetime.cast("2026-10-13T09:30:00.25")
          # A time that the clocks of the time zone skip, which a local time would move by an hour.
          assert_equal Time.utc(2026, 3, 8, 2, 30), pattern.cast("2026-03-08 02:30")
        ensure
          ENV["TZ"] = original
        end

        it "reads text with a zone at its offset, and raises for a zone whose offset is not known" do
          zone = field(type: "datetime", format: "%Y-%m-%d %H:%M %Z")

          assert_equal Time.utc(2026, 10, 13, 8, 30), zone.cast("2026-10-13 09:30 CET")
          assert_equal 3600, zone.cast("2026-10-13 09:30 CET").utc_offset
          assert_equal Time.utc(2026, 10, 13, 14, 30), zone.cast("2026-10-13 09:30 EST")
          error = assert_raises(IOStreams::Errors::InvalidValue) { zone.cast("2026-10-13 09:30 XYZ") }
          assert_equal 'Field "value": "2026-10-13 09:30 XYZ" is not a valid datetime', error.message
        end

        it "raises for a date without a time, or another form" do
          ["2026-10-13", "2026-10-13T25:00:00Z", "2026-10-13T09:30Z", "2026-10-13  09:30:00", "2026-10-13T09:30:00+5",
           "2026-10-13T09:30:00+05:3", "2026-10-13T09:30:00 +05:30", "2026-10-13t09:30:00", "2026-10-13T09:30:00z"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { datetime.cast(text) }
          end
        end

        it "reads an offset of hours alone, such as +05, as PostgreSQL writes it, and -0000 as UTC" do
          time = datetime.cast("2026-10-31 09:30:00+05")

          assert_equal Time.utc(2026, 10, 31, 4, 30), time
          assert_equal 18_000, time.utc_offset
          assert_equal(-28_800, datetime.cast("2026-10-31T09:30:00.25-08").utc_offset)
          assert_equal Time.utc(2026, 10, 31, 9, 30), datetime.cast("2026-10-31T09:30:00-0000")
          assert_equal 0, datetime.cast("2026-10-31T09:30:00-0000").utc_offset
          assert_predicate datetime.cast("2026-10-31T09:30:00-0000"), :utc?
          assert_equal Time.new(2000, 1, 1, 9, 30, 0, "+05:00"), field(type: "time").cast("09:30:00+05")
        end

        it "raises for minutes of an offset, or seconds, of 60 or more, and for text after a line break" do
          ["2026-10-13T09:30:00+0560", "2026-10-13T09:30:00+05:60", "2026-10-13T09:30:00+053", "2026-10-13T23:59:60Z",
           "2026-10-13T09:30:00Z\njunk", "2026-10-13T09:30:00\njunk"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text.inspect) { datetime.cast(text) }
          end
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "time").cast("09:30:00+0560") }
        end

        it "reads a format without a year in 1900, on 1900-01-01 without a day, as Python's strptime does, not today" do
          clock = field(type: "datetime", format: "%H:%M")

          assert_equal Time.utc(1900, 1, 1, 9, 30), clock.cast("09:30")
          assert_equal Time.utc(1900, 1, 1, 21, 30), field(type: "datetime", format: "%I:%M %p").cast("09:30 PM")
          assert_equal Time.new(1900, 1, 1, 9, 30, 0, "+05:00"), field(type: "datetime", format: "%H:%M %z").cast("09:30 +0500")
          assert_equal Time.utc(1900, 7, 1, 9, 30), field(type: "datetime", format: "%m %H:%M").cast("07 09:30")
          assert_equal Time.utc(1900, 7, 1, 9, 30), field(type: "datetime", format: "%j %H:%M").cast("182 09:30")
          assert_equal Time.utc(1901, 1, 1), field(type: "datetime", format: "%j").cast("366")
          assert_equal Date.new(1900, 3, 1), field(type: "date", format: "%j").cast("060")
          # A weekday, or a week, without a year is ignored.
          assert_equal Time.utc(1900, 1, 1, 9, 30), field(type: "datetime", format: "%U %a %H:%M").cast("10 Mon 09:30")
          assert_equal Time.utc(1900, 1, 1, 9, 30), field(type: "datetime", format: "%a %H:%M").cast("Tue 09:30")
          assert_equal Date.new(1900, 7, 1), field(type: "date", format: "%m").cast("07")
          assert_equal Date.new(1900, 7, 1), field(type: "date", format: "%B").cast("July")
          assert_equal Time.new(1900, 1, 1, 9, 30, 0, "-05:00"),
                       field(type: "datetime", format: "%H:%M", timeZone: "America/New_York").cast("09:30")
          # A date with a year, or read some other way, and a time of day, are unchanged.
          assert_equal Time.utc(2026, 7, 1, 9, 30), field(type: "datetime", format: "%Y %j %H:%M").cast("2026 182 09:30")
          assert_equal Time.utc(2026, 3, 2), field(type: "datetime", format: "%G %V %u").cast("2026 10 1")
          assert_equal Time.utc(2000, 1, 1, 9, 30), field(type: "time", format: "%H:%M").cast("09:30")
        end

        it "writes a time whose offset has seconds, such as a zone's local mean time of 1900, in UTC, which reads back" do
          kolkata = field(type: "datetime", format: "%H:%M", timeZone: "Asia/Kolkata")
          time    = kolkata.cast("09:30")

          assert_equal 19_270, time.utc_offset
          assert_equal "1900-01-01T04:08:50Z", kolkata.dump(time)
          assert_equal time, kolkata.load(kolkata.dump(time))
          assert_equal "1900-01-01T04:08:50Z", field(type: "datetime").render(time, :text)
          assert_equal "2026-07-01T09:30:00+05:30", field(type: "datetime").render(Time.new(2026, 7, 1, 9, 30, 0, "+05:30"), :text)
        end

        it "raises when the schema is built for a format of a day of the month without a year, as Python 3.15 does" do
          ["%m/%d", "%d %H:%M", "%e %b", "%Od/%m %H:%M", "%-d.%m."].each do |format|
            %w[date datetime time].each do |type|
              error = assert_raises(ArgumentError, format) { field(type: type, format: format) }

              assert_match(/\AField "value": the format #{Regexp.escape(format.inspect)} reads a day of the month without a year.* add a year/,
                           error.message)
            end
          end
          # An ISO 8601 week without its year, week and weekday, or with the day of the year, as Python raises for it.
          ["%V %u", "%G-%m-%d", "%Y %V %u", "%G %V", "%G %j"].each do |format|
            error = assert_raises(ArgumentError, format) { field(type: "date", format: format) }

            assert_match(/ISO 8601 week/, error.message, format)
          end
          # A year of any kind, or a composite that reads one, such as %D, which is %m/%d/%y.
          ["%d/%m/%Y", "%d/%m/%y", "%D", "%x", "%G %V %u %d"].each do |format|
            assert_kind_of IOStreams::Schema::Field, field(type: "date", format: format), format
          end
        end

        it "raises for an hour of 24, as a time does, rather than read the midnight of the next day" do
          pattern = field(type: "datetime", format: "%Y-%m-%d %H:%M:%S")
          ["2026-10-13T24:00:00", "2026-10-13T24:00:00Z", "2026-12-31 24:00:00+05:00", "2026-10-13T23:60:00Z"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text.inspect) { datetime.cast(text) }
            assert_raises(IOStreams::Errors::InvalidValue, text.inspect) { datetime.load(text) }
          end
          ["2026-10-13 24:00:00", "2026-10-13 23:59:60"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text.inspect) { pattern.cast(text) }
          end
          assert_equal Time.utc(2026, 10, 13, 23, 59, 59), pattern.cast("2026-10-13 23:59:59")
          assert_equal Time.utc(2026, 10, 13, 23, 59, 59), datetime.cast("2026-10-13T23:59:59Z")
          assert_equal Time.utc(2026, 10, 13, 21, 30), field(type: "datetime", format: "%Y-%m-%d %I:%M %p").cast("2026-10-13 09:30 PM")
        end

        it "reads a space in place of the T, as databases write it, and an offset without a colon" do
          assert_equal Time.utc(2026, 10, 13, 9, 30), datetime.cast("2026-10-13 09:30:00")
          assert_predicate datetime.cast("2026-10-13 09:30:00"), :utc?
          assert_equal Time.new(2026, 10, 13, 9, 30, 0.5r, "+05:30"), datetime.cast("2026-10-13 09:30:00.5+0530")
          assert_equal(-18_000, datetime.cast("2026-10-13T09:30:00-0500").utc_offset)
          assert_equal Time.utc(2026, 10, 13, 9, 30), datetime.cast("2026-10-13 09:30:00Z")
          assert_raises(IOStreams::Errors::InvalidValue) { datetime.cast("2026-02-30 09:30:00") }
          assert_equal "2026-10-13T09:30:00Z", datetime.render("2026-10-13 09:30:00", :text)
          assert_equal "2026-10-13T09:30:00-05:00", datetime.render("2026-10-13 09:30:00-0500", :text)
        end

        it "raises for a date that does not exist, rather than move it into the next month" do
          pattern = field(type: "datetime", format: "%Y-%m-%d %H:%M")

          ["2026-02-30T10:00:00Z", "2026-02-29T10:00:00Z", "2026-04-31T10:00:00+05:30"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { datetime.cast(text) }
          end
          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("2026-02-30 10:00") }
          assert_equal Time.utc(2028, 2, 29, 10), datetime.cast("2028-02-29T10:00:00Z")
          leap = pattern.cast("2028-02-29 10:00")

          assert_equal [2028, 2, 29, 10], [leap.year, leap.month, leap.day, leap.hour]
        end

        it "converts a DateTime at its offset, even when DateTime#to_time converts it to the local time zone" do
          value = DateTime.new(2026, 10, 13, 9, 30, 0.25r, "+05:30")
          # As ActiveSupport 7 does, unless `ActiveSupport.to_time_preserves_timezone` is set.
          def value.to_time = super.getlocal("-04:00")

          time = datetime.cast(value)

          assert_equal Time.new(2026, 10, 13, 9, 30, 0.25r, "+05:30"), time
          assert_equal 19_800, time.utc_offset
        end

        it "renders ISO 8601, with as many digits of the fraction of a second as it needs" do
          assert_equal "2026-10-13T09:30:00Z", datetime.render(Time.utc(2026, 10, 13, 9, 30), :text)
          assert_equal "2026-10-13T09:30:00.250Z", datetime.render(Time.utc(2026, 10, 13, 9, 30, 0.25r), :text)
          assert_equal "2026-10-13T09:30:00.000001Z", datetime.render(Time.utc(2026, 10, 13, 9, 30, 0.000001r), :text)
        end

        it "writes a DateTime at UTC with Z, as a Time in UTC, since a DateTime does not tell UTC from an offset of 0" do
          value = DateTime.new(2026, 10, 13, 9, 30, 0.25r)

          assert_equal "2026-10-13T09:30:00.250Z", datetime.render(value, :text)
          assert_equal "2026-10-13T09:30:00.250Z", datetime.render(value, :json)
          assert_equal "2026-10-13T09:30:00.250Z", datetime.dump(value)
          assert_equal "2026-10-13T09:30:00.250Z", field(type: "any").render(value, :text)
          assert_predicate datetime.cast(value), :utc?
          assert_equal "09:30:00Z", field(type: "time").dump(field(type: "time").cast(DateTime.new(2026, 10, 13, 9, 30)))
          assert_equal "2026-10-13T09:30:00+05:30", datetime.render(DateTime.new(2026, 10, 13, 9, 30, 0, "+05:30"), :text)
        end

        it "reads and writes the format" do
          pattern = field(type: "datetime", format: "%Y%m%d%H%M%S%z")

          assert_equal Time.utc(2026, 10, 13, 9, 30), pattern.cast("20261013093000+0000")
          assert_equal "20261013093000+0000", pattern.render(Time.utc(2026, 10, 13, 9, 30), :text)
        end

        it "reads the microseconds of %f, as Python's strptime does, 1 to 6 digits, and writes 6" do
          pattern = field(type: "datetime", format: "%Y-%m-%d %H:%M:%S.%f")

          assert_equal Time.utc(2026, 10, 13, 9, 30, 0.5r), pattern.cast("2026-10-13 09:30:00.5")
          assert_equal Time.utc(2026, 10, 13, 9, 30, 0.123456r), pattern.cast("2026-10-13 09:30:00.123456")
          ["2026-10-13 09:30:00.1234567", "2026-10-13 09:30:00.", "2026-10-13 09:30:00"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { pattern.cast(text) }
          end
          assert_equal "2026-10-13 09:30:00.500000", pattern.render(Time.utc(2026, 10, 13, 9, 30, 0.5r), :text)
          assert_equal "2026-10-13 09:30:00.000000", pattern.render(Time.utc(2026, 10, 13, 9, 30), :text)
        end

        it "reads whole seconds for %s, ignoring the fraction after it" do
          assert_equal Time.utc(2026, 10, 13, 9, 30), field(type: "datetime", format: "%s.%f").cast("1791883800.5")
        end

        it "reads %c with exactly 4 digits for its year, and writes it as Ruby does" do
          pattern = field(type: "datetime", format: "%c")

          assert_equal Time.utc(2026, 10, 31, 9, 30), pattern.cast("Sat Oct 31 09:30:00 2026")
          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("Sat Oct 31 09:30:00 26") }
          assert_equal "Sat Oct 31 09:30:00 2026", pattern.render(Time.utc(2026, 10, 31, 9, 30), :text)
        end

        it "reads the microseconds of %f right after the seconds" do
          pattern = field(type: "datetime", format: "%Y%m%d%H%M%S%f")

          assert_equal Time.utc(2026, 10, 31, 9, 30, 0.123r), pattern.cast("20261031093000123")
          assert_equal "20261031093000123000", pattern.render(Time.utc(2026, 10, 31, 9, 30, 0.123r), :text)
        end

        it "reads the microseconds of %f right after the 2 digits of %y" do
          pattern = field(type: "datetime", format: "%m/%d/%y%f")

          assert_equal Time.utc(2026, 10, 31, 0, 0, 0.123r), pattern.cast("10/31/26123")
          assert_equal "10/31/26123000", pattern.render(Time.utc(2026, 10, 31, 0, 0, 0.123r), :text)
        end

        it "reads %+ with exactly 4 digits for its year, and writes it as the strftime of a Date does" do
          pattern = field(type: "datetime", format: "%+")

          assert_equal Time.utc(2026, 10, 31, 9, 30), pattern.cast("Sat Oct 31 09:30:00 UTC 2026")
          assert_equal Time.utc(2026, 10, 31, 13, 30), pattern.cast("Sat Oct 31 09:30:00 -04:00 2026")
          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("Sat Oct 31 09:30:00 UTC 26") }
          assert_equal "Sat Oct 31 09:30:00 +00:00 2026", pattern.render(Time.utc(2026, 10, 31, 9, 30), :text)
          assert_equal "Sat Oct 31 09:30:00 -04:00 2026", pattern.render(Time.new(2026, 10, 31, 9, 30, 0, "-04:00"), :text)
        end

        it "reads and writes Ruby's own directives, which are not portable, such as %N, %L and %s" do
          nanoseconds = field(type: "datetime", format: "%Y-%m-%d %H:%M:%S.%N")
          millis      = field(type: "datetime", format: "%Y-%m-%d %H:%M:%S.%L")

          assert_equal Time.utc(2026, 10, 13, 9, 30, 0.123456789r), nanoseconds.cast("2026-10-13 09:30:00.123456789")
          assert_equal "2026-10-13 09:30:00.123456789", nanoseconds.render(Time.utc(2026, 10, 13, 9, 30, 0.123456789r), :text)
          assert_equal "2026-10-13 09:30:00.250", millis.render(Time.utc(2026, 10, 13, 9, 30, 0.25r), :text)
          assert_equal Time.utc(2026, 10, 13, 9, 30), field(type: "datetime", format: "%s").cast("1791883800")
        end

        it "keeps an offset of zero that the text says with a format, such as +0000, while Z and -0000 are UTC, as without a format" do
          pattern = field(type: "datetime", format: "%Y-%m-%d %H:%M %z")

          ["+0000", "+00:00"].each do |zone|
            time = pattern.cast("2026-10-13 09:30 #{zone}")

            assert_equal Time.utc(2026, 10, 13, 9, 30), time
            refute_predicate time, :utc?, zone
            assert_equal 0, time.utc_offset
            assert_equal "2026-10-13T09:30:00+00:00", datetime.render(time, :text)
          end
          ["Z", "-0000", "-00:00", "UTC"].each do |zone|
            time = pattern.cast("2026-10-13 09:30 #{zone}")

            assert_equal Time.utc(2026, 10, 13, 9, 30), time
            assert_predicate time, :utc?, zone
          end
          %w[+0000 -0000 Z].each do |zone|
            assert_equal datetime.cast("2026-10-13T09:30:00#{zone}").utc?, pattern.cast("2026-10-13 09:30 #{zone}").utc?, zone
          end
          assert_equal 19_800, pattern.cast("2026-10-13 09:30 +0530").utc_offset
          assert_predicate field(type: "datetime", format: "%Y-%m-%d %H:%M").cast("2026-10-13 09:30"), :utc?
          assert_equal "09:30:00+00:00", field(type: "time", format: "%H:%M %z").dump(field(type: "time", format: "%H:%M %z").cast("09:30 +0000"))
        end

        it "writes a time in UTC with a format without a zone, which reads it back as UTC, as the same time" do
          pattern = field(type: "datetime", format: "%Y-%m-%d %H:%M")
          time    = Time.new(2026, 10, 13, 9, 30, 0, "-04:00")

          assert_equal "2026-10-13 13:30", pattern.render(time, :text)
          assert_equal time, pattern.cast(pattern.render(time, :text))
        end

        it "writes a time at its own offset with a format that has a zone" do
          time = Time.new(2026, 10, 13, 9, 30, 0, "-04:00")

          assert_equal "2026-10-13 09:30 -0400", field(type: "datetime", format: "%Y-%m-%d %H:%M %z").render(time, :text)
          assert_equal "2026-10-13 09:30 -04:00", field(type: "datetime", format: "%Y-%m-%d %H:%M %:z").render(time, :text)
          assert_equal "100% 2026-10-13 13:30", field(type: "datetime", format: "100%% %Y-%m-%d %H:%M").render(time, :text)
        end
      end

      describe "#load" do
        it "raises for a date that does not exist, or a time that is not on a clock, as #cast does" do
          datetime = field(type: "datetime", format: "%d/%m/%Y %H:%M")
          clock    = field(type: "time", format: "%H.%M")
          date     = field(type: "date", format: "%d/%m/%Y")
          {
            datetime => ["2026-02-30T09:30:00Z", "2026-04-31T09:30:00+05:00", "2026-10-13T24:00:00Z", "2026-10-13T23:59:60Z"],
            clock    => ["24:00:00", "23:59:60Z", "23:60:00+05:00"]
          }.each do |field, texts|
            texts.each do |text|
              assert_raises(IOStreams::Errors::InvalidValue, text) { field.load(text) }
            end
          end

          assert_equal Time.utc(2026, 2, 28, 9, 30), datetime.load("2026-02-28T09:30:00Z")
          assert_equal Time.utc(2028, 2, 29, 9, 30), datetime.load("2028-02-29T09:30:00Z")
          assert_raises(IOStreams::Errors::InvalidValue) { datetime.load("2026-10-00T09:30:00Z") }
          assert_raises(IOStreams::Errors::InvalidValue) { datetime.load("2026-13-01T09:30:00Z") }
          assert_equal Time.new(2000, 1, 1, 23, 59, 59, "+05:00"), clock.load("23:59:59+05:00")
          assert_equal Date.new(2026, 2, 28), date.load("2026-02-28")
        end

        it "checks the constraints of a date, datetime or time, as for any other type" do
          {
            field(type: "date", constraints: {maximum: "2026-01-01"})               => "2026-06-01",
            field(type: "datetime", constraints: {maximum: "2026-01-01T00:00:00Z"}) => "2026-06-01T00:00:00Z",
            field(type: "time", constraints: {maximum: "12:00:00"})                 => "13:00:00Z"
          }.each do |field, text|
            error = assert_raises(IOStreams::Errors::InvalidValue, text) { field.load(text) }
            assert_match(/more than its maximum/, error.message)
          end
        end
      end

      describe "time" do
        let(:clock) { field(type: "time") }

        it "reads ISO 8601 as a time of day, a Time on 2000-01-01, in UTC without an offset, whatever the time zone" do
          original  = ENV.fetch("TZ", nil)
          ENV["TZ"] = "America/New_York"

          [clock.cast("09:30:00"), clock.cast("09:30:00Z")].each do |value|
            assert_equal Time.utc(2000, 1, 1, 9, 30), value
            assert_predicate value, :utc?
          end
          assert_equal Time.utc(2000, 1, 1, 23, 59, 59.999999r), clock.cast("23:59:59.999999")
          assert_equal Time.utc(2000, 1, 1, 9, 30), clock.cast(" 09:30:00 ")
        ensure
          ENV["TZ"] = original
        end

        it "keeps the offset of text that has one, and the time of its clock" do
          value = clock.cast("09:30:00.250-05:00")

          assert_equal Time.new(2000, 1, 1, 9, 30, 0.25r, "-05:00"), value
          assert_equal(-18_000, value.utc_offset)
          assert_equal "09:30:00.250", clock.render("09:30:00.250-05:00", :text)
        end

        it "reads an offset without a colon, as a datetime does" do
          assert_equal Time.new(2000, 1, 1, 9, 30, 0, "+05:30"), clock.cast("09:30:00+0530")
          assert_equal(-18_000, clock.cast("09:30:00.5-0500").utc_offset)
          assert_raises(IOStreams::Errors::InvalidValue) { clock.cast("09:30:00+053") }
        end

        it "raises for another form, or a time that is not on a clock, rather than move it into the next day" do
          ["9:30:00", "09:30", "24:00:00", "23:60:00", "23:59:60", "09:30:00 PM", "09:30:00+5", "2026-10-13T09:30:00Z"].each do |text|
            error = assert_raises(IOStreams::Errors::InvalidValue, text) { clock.cast(text) }
            assert_equal "Field \"value\": #{text.inspect} is not a valid time", error.message
          end
          assert_raises(IOStreams::Errors::InvalidValue) { clock.cast(34_200) }
          assert_raises(IOStreams::Errors::InvalidValue) { clock.cast(Date.new(2026, 10, 13)) }
        end

        it "moves a Time or a DateTime on another day to 2000-01-01, keeping the time of its clock and its offset" do
          assert_equal Time.new(2000, 1, 1, 9, 30, 0.25r, "-04:00"), clock.cast(Time.new(2026, 7, 15, 9, 30, 0.25r, "-04:00"))
          assert_predicate clock.cast(Time.utc(2026, 7, 15, 9, 30)), :utc?
          assert_equal Time.new(2000, 1, 1, 9, 30, 0, "+05:30"), clock.cast(DateTime.new(2026, 7, 15, 9, 30, 0, "+05:30"))
          # As Active Record holds the time of day of a Rails app in its time zone, on the day before.
          assert_equal Time.new(2000, 1, 1, 22, 0, 0, "-05:00"), clock.cast(Time.new(1999, 12, 31, 22, 0, 0, "-05:00"))
        end

        it "keeps a Time that is already on 2000-01-01" do
          value = Time.new(2000, 1, 1, 9, 30, 0, "-05:00")

          assert_same value, clock.cast(value)
          assert_same value, clock.render(value, :typed)
        end

        it "writes the time of its clock, without its offset, with as many digits of a fraction of a second as it needs" do
          assert_equal "09:30:00", clock.render(Time.utc(2000, 1, 1, 9, 30), :text)
          assert_equal "09:30:00", clock.render(Time.new(2026, 7, 15, 9, 30, 0, "-04:00"), :text)
          assert_equal "09:30:00.250", clock.render(Time.utc(2000, 1, 1, 9, 30, 0.25r), :text)
          assert_equal "09:30:00.000001", clock.render(Time.utc(2000, 1, 1, 9, 30, 0.000001r), :text)
          assert_equal "09:30:00.000000001", clock.render(Time.utc(2000, 1, 1, 9, 30, 0.000000001r), :text)
          assert_equal "23:45:00", clock.render(Time.utc(2000, 1, 1, 23, 45), :json)
        end

        it "reads and writes the format" do
          pattern = field(type: "time", format: "%I:%M %p")

          assert_equal Time.utc(2000, 1, 1, 21, 30), pattern.cast("9:30 PM")
          assert_equal Time.utc(2000, 1, 1, 0, 0), pattern.cast("12:00 AM")
          assert_equal "09:30 PM", pattern.render(Time.utc(2000, 1, 1, 21, 30), :text)
          assert_equal "09:30 PM", pattern.render(Time.new(2026, 7, 15, 21, 30, 0, "-04:00"), :json)
          ["13:30 PM", "9:30", "9:30 PM extra"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { pattern.cast(text) }
          end
        end

        it "reads and writes the microseconds of %f" do
          pattern = field(type: "time", format: "%H:%M:%S.%f")

          assert_equal Time.utc(2000, 1, 1, 9, 30, 0.25r), pattern.cast("09:30:00.25")
          assert_equal "09:30:00.250000", pattern.render(Time.utc(2000, 1, 1, 9, 30, 0.25r), :text)
          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("09:30:00.2500000") }
        end

        it "reads a zone of the format at its offset, raises for a zone whose offset is not known, and for 24:00" do
          zone = field(type: "time", format: "%H:%M %Z")

          assert_equal Time.new(2000, 1, 1, 9, 30, 0, "+01:00"), zone.cast("09:30 CET")
          assert_equal 3600, zone.cast("09:30 CET").utc_offset
          assert_raises(IOStreams::Errors::InvalidValue) { zone.cast("09:30 XYZ") }
          assert_raises(IOStreams::Errors::InvalidValue) { zone.cast("24:00 UTC") }
          assert_equal "09:30 +0100", field(type: "time", format: "%H:%M %z").render(zone.cast("09:30 CET"), :text)
        end
      end

      describe "duration" do
        let(:duration) { field(type: "duration") }

        it "reads ISO 8601 as an ActiveSupport::Duration, keeping its months and days apart from its seconds" do
          value = duration.cast("P1M2DT3H")

          assert_instance_of ActiveSupport::Duration, value
          assert_equal({months: 1, days: 2, hours: 3}, value.parts)
          assert_equal({seconds: 0.5}, duration.cast("PT0.5S").parts)
          assert_equal({days: -1}, duration.cast("-P1D").parts)
          assert_equal({hours: 8, minutes: 30}, duration.cast(" PT8H30M ").parts)
        end

        it "keeps a Duration as it is" do
          value = duration.cast("PT8H30M")

          assert_same value, duration.cast(value)
          assert_same value, duration.render(value, :typed)
        end

        it "raises for other text, and for a number, which does not say what it counts" do
          ["P", "PT", "1 day", "PT1H30", "p1d", "30600", "08:30:00"].each do |text|
            error = assert_raises(IOStreams::Errors::InvalidValue, text) { duration.cast(text) }
            assert_equal "Field \"value\": #{text.inspect} is not a valid duration", error.message
          end
          assert_raises(IOStreams::Errors::InvalidValue) { duration.cast(30_600) }
          assert_raises(IOStreams::Errors::InvalidValue) { duration.cast(1.5) }
        end

        it "restores the seconds that a store keeps of a duration that it rendered, such as BSON" do
          assert_equal "PT8H30M", duration.restore(30_600).iso8601
          assert_equal "PT1.5S", duration.restore(1.5).iso8601
          assert_instance_of ActiveSupport::Duration, duration.restore(30_600)

          value = duration.cast("P1M2DT3H")

          assert_same value, duration.restore(value)
          assert_equal({months: 1, days: 2, hours: 3}, duration.restore("P1M2DT3H").parts)
          assert_nil duration.restore(nil)
        end

        it "raises to restore what a duration is never stored as" do
          [Float::INFINITY, Float::NAN, "30600", Date.new(2026, 1, 2)].each do |value|
            assert_raises(IOStreams::Errors::InvalidValue, value.inspect) { duration.restore(value) }
          end
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "duration", constraints: {required: true}).restore(nil) }
        end

        it "restores the value of any other field as it casts it, since only a duration has a form of its own" do
          assert_equal Date.new(2026, 1, 2), field(type: "date").restore(Time.utc(2026, 1, 2))
          assert_equal 12, field(type: "integer").restore("12")
          assert_equal 300, field(type: "any").restore(300)
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "date").restore(300) }
        end

        it "writes ISO 8601, also in JSON" do
          assert_equal "P1M2DT3H", duration.render("P1M2DT3H", :text)
          # The field loads ActiveSupport::Duration, so it is loaded only once the field is created.
          assert_equal "PT8H30M", duration.render(ActiveSupport::Duration.build(30_600), :text)
          assert_equal "PT0.5S", duration.render("PT0.5S", :json)
        end

        it "raises for a format, which only a date, a datetime or a time has" do
          assert_raises(ArgumentError) { field(type: "duration", format: "%H:%M") }
        end

        it "raises LoadError when the activesupport gem is not installed, naming it" do
          # A new process, since the tests have already loaded ActiveSupport::Duration, which hides it, as if it were not
          # installed.
          script = <<~'RUBY'
            module Kernel
              alias_method :require_installed, :require

              def require(name)
                raise(LoadError, "cannot load such file -- #{name}") if name.start_with?("active_support")

                require_installed(name)
              end
            end
            require "iostreams"
            begin
              IOStreams::Schema.new(fields: [{name: "length", type: "duration"}])
            rescue LoadError => e
              print e.message
            end
          RUBY
          lib     = File.expand_path("../lib", __dir__)
          message = IO.popen([RbConfig.ruby, "-I", lib, "-e", script], err: File::NULL, &:read)

          assert_equal 'Field "length": a duration field needs the activesupport gem, whose ActiveSupport::Duration ' \
                       'holds its values, so add `gem "activesupport"` to the Gemfile: cannot load such file -- ' \
                       "active_support/duration", message
        end
      end

      describe "object" do
        let(:object) { field(type: "object") }

        it "reads the text of a JSON object, with its numbers as JSON reads them without a schema" do
          assert_equal({"a" => 1, "b" => [1.5, "x", nil]}, object.cast(' {"a":1,"b":[1.5,"x",null]} '))
        end

        it "keeps a Hash as it is, when it is what JSON holds" do
          prefs = {"a" => 1, "b" => [1.5, "x", nil, true, {"c" => false}]}

          assert_same prefs, object.cast(prefs)
        end

        it "keeps a value of another class as it is, which can differ from the value that its JSON text reads" do
          prefs = {"ratio" => Rational(1, 2)}

          assert_equal({"ratio" => Rational(1, 2)}, object.cast(prefs))
          assert_equal({"ratio" => "1/2"}, object.cast(object.render(prefs, :text)))
        end

        it "raises for Hashes and Arrays nested more than 100 deep, as JSON reads them, such as a Hash that holds itself" do
          deep = 99.times.reduce({"a" => 1}) { |inner, _| {"a" => inner} }

          assert_equal deep, object.cast(deep)
          error = assert_raises(IOStreams::Errors::InvalidValue) { object.cast({"a" => deep}) }
          assert_includes error.message, 'Field "value": '
          assert_raises(IOStreams::Errors::InvalidValue) { object.cast({b: deep}) }
          itself = {"a" => 1}
          itself["b"] = itself
          assert_raises(IOStreams::Errors::InvalidValue) { object.cast(itself) }
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "array").cast([[deep]]) }
        end

        it "raises for Hashes and Arrays nested more than 100 deep when it writes them, with or without the json gem's coder" do
          deep   = 99.times.reduce({"a" => 1}) { |inner, _| {"a" => inner} }
          itself = {"a" => 1}
          itself["b"] = itself

          json_writers.each do |coder|
            IOStreams::Tabular::Parser::Json.stub(:coder, coder) do
              assert_equal JSON.generate(deep), object.render(deep, :text)
              [{"a" => deep}, itself].each do |value|
                %i[text json].each do |form|
                  error = assert_raises(IOStreams::Errors::InvalidValue) { object.render(value, form) }
                  assert_includes error.message, 'Field "value": '
                end
              end
            end
          end
        end

        it "raises InvalidValue naming the field for a number within it that is not finite, which JSON cannot hold" do
          array = field(type: "array")
          any   = field(type: "any")

          json_writers.each do |coder|
            IOStreams::Tabular::Parser::Json.stub(:coder, coder) do
              [[object, {"a" => Float::NAN}], [array, [1, Float::INFINITY]], [any, [-Float::INFINITY]]].each do |field, value|
                forms = field == any ? %i[text] : %i[text json scalar]
                forms.each do |form|
                  error = assert_raises(IOStreams::Errors::InvalidValue) { field.render(value, form) }
                  assert_equal "value", error.field
                  assert_match(/\AField "value": JSON cannot hold a number that is not finite: (NaN|INF|-INF)\z/, error.message)
                end
              end
              # A BigDecimal within it is written as its text, as JSON holds it.
              assert_equal '{"a":"NaN"}', object.render({"a" => BigDecimal("NaN")}, :text)
            end
          end
        end

        it "raises InvalidValue naming the key for a number that is not finite within a record written to JSON" do
          json_writers.each do |coder|
            IOStreams::Tabular::Parser::Json.stub(:coder, coder) do
              [nil, {"fields" => [{"name" => "id"}, {"name" => "sizes"}]}].each do |schema|
                stream = IOStreams.stream(StringIO.new).format(:json)
                stream.schema(schema) if schema
                error = assert_raises(IOStreams::Errors::InvalidValue) do
                  stream.writer(:hash) { |io| io << {"id" => 1, "sizes" => [1.5, Float::NAN]} }
                end

                assert_equal "sizes", error.field
                assert_equal 'Field "sizes": JSON cannot hold a number that is not finite: NaN', error.reason
              end
              %i[csv psv].each do |format|
                error = assert_raises(IOStreams::Errors::InvalidValue) do
                  IOStreams.stream(StringIO.new).format(format).writer(:hash) { |io| io << {"id" => 1, "sizes" => [Float::NAN]} }
                end

                assert_equal "sizes", error.field
                assert_equal 'Field "sizes": JSON cannot hold a number that is not finite: NaN', error.reason
              end
            end
          end
        end

        it "reads a Hash or an Array read from JSON as it is, which JSON already holds, and converts one of any other form" do
          prefs = {"limit" => 12.5, "tags" => ["a", {"b" => nil}]}
          typed = {limit: BigDecimal("12.5")}

          assert_same prefs, object.parse(prefs, :json)
          assert_equal({"limit" => "12.5"}, object.parse(typed, :typed))
          assert_equal({"a" => 1}, object.parse('{"a":1}', :json))
          assert_nil object.parse("", :json)
          assert_raises(IOStreams::Errors::InvalidValue) { object.parse([1], :json) }
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "array").parse({"a" => 1}, :json) }
        end

        it "converts a Hash to what JSON holds of it, so that a :hash source reads what JSON does" do
          prefs = {
            :limit => BigDecimal("12.5"), "on" => Date.new(2026, 10, 13), "at" => Time.utc(2026, 10, 13, 9, 30),
            "kind" => :gold, "tags" => [:a, {b: BigDecimal("1")}], 7 => "seven"
          }
          json = {
            "limit" => "12.5", "on" => "2026-10-13", "at" => "2026-10-13T09:30:00Z", "kind" => "gold",
            "tags" => ["a", {"b" => "1.0"}], "7" => "seven"
          }

          assert_equal json, object.cast(prefs)
          assert_equal JSON.parse(object.render(prefs, :text)), object.cast(prefs)
          assert_equal json, object.render(prefs, :typed)
          assert_equal({limit: BigDecimal("12.5")}, prefs.slice(:limit), "the Hash supplied is not changed")
        end

        it "reads empty text as nil, and raises for text of only whitespace" do
          assert_nil object.cast("")
          assert_raises(IOStreams::Errors::InvalidValue) { object.cast("  ") }
        end

        it "raises for text that is not a JSON object, and for a value that is not a Hash" do
          ["[1]", "5", '"a"', "{a:1}", "not json"].each do |text|
            error = assert_raises(IOStreams::Errors::InvalidValue) { object.cast(text) }
            assert_equal "Field \"value\": #{text.inspect} is not a valid object", error.message
          end
          assert_raises(IOStreams::Errors::InvalidValue) { object.cast([1]) }
          assert_raises(IOStreams::Errors::InvalidValue) { object.cast(1) }
        end

        it "writes its JSON text, or itself in JSON, with a BigDecimal, Date or Time within it as text" do
          prefs = {"limit" => BigDecimal("12.5"), "on" => Date.new(2026, 10, 13), "tags" => [1, nil]}

          assert_equal %({"limit":"12.5","on":"2026-10-13","tags":[1,null]}), object.render(prefs, :text)
          # Its JSON text, which JSON writes as it is, converted once, as the JSON format converts it.
          assert_equal JSON::Fragment.new(%({"limit":"12.5","on":"2026-10-13","tags":[1,null]})), object.render(prefs, :json)
          json_writers.each do |coder|
            assert_equal %({"limit":"12.5","on":"2026-10-13","tags":[1,null]}),
                         IOStreams::Tabular::Parser::Json.generate(object.render(prefs, :json), coder)
          end
          assert_equal({"limit" => "12.5", "on" => "2026-10-13", "tags" => [1, nil]}, object.render(prefs, :typed))
        end

        it "raises for a format, which only a date or a datetime has" do
          assert_raises(ArgumentError) { field(type: "object", format: "%Y") }
        end
      end

      describe "array" do
        let(:array) { field(type: "array") }

        it "reads the text of a JSON array" do
          assert_equal [1, "a", nil, {"b" => 2.5}], array.cast('[1,"a",null,{"b":2.5}]')
        end

        it "converts an Array to what JSON holds of it" do
          list = [:a, BigDecimal("1.5"), Date.new(2026, 10, 13), {k: 1}]

          assert_equal ["a", "1.5", "2026-10-13", {"k" => 1}], array.cast(list)
          assert_equal [:a, BigDecimal("1.5"), Date.new(2026, 10, 13), {k: 1}], list
        end

        it "keeps an Array as it is, and raises for a Hash, or the text of a JSON object" do
          list = [1, 2]

          assert_same list, array.cast(list)
          assert_raises(IOStreams::Errors::InvalidValue) { array.cast({"a" => 1}) }
          error = assert_raises(IOStreams::Errors::InvalidValue) { array.cast('{"a":1}') }
          assert_equal %(Field "value": "{\\"a\\":1}" is not a valid array), error.message
        end

        it "writes its JSON text, or itself in JSON" do
          list = [BigDecimal("1.5"), Time.utc(2026, 10, 13, 9, 30), "x"]

          assert_equal %(["1.5","2026-10-13T09:30:00Z","x"]), array.render(list, :text)
          assert_equal JSON::Fragment.new(%(["1.5","2026-10-13T09:30:00Z","x"])), array.render(list, :json)
          json_writers.each do |coder|
            assert_equal %(["1.5","2026-10-13T09:30:00Z","x"]), IOStreams::Tabular::Parser::Json.generate(array.render(list, :json), coder)
          end
        end
      end

      describe "any" do
        it "returns the value as it is" do
          any = field

          assert_equal " 12 ", any.cast(" 12 ")
          assert_equal [1], any.render([1], :json)
          assert_equal "12", any.render(12, :text)
        end

        it "writes a BigDecimal, Date or Time as its usual text" do
          any = field

          assert_equal "12.5", any.render(BigDecimal("12.5"), :text)
          assert_equal "12.5", any.render(BigDecimal("12.5"), :json)
          assert_equal "2026-10-13T09:30:00Z", any.render(Time.utc(2026, 10, 13, 9, 30), :text)
          record = {"at" => Date.new(2026, 10, 13)}

          assert_same record, any.render(record, :json)
          json_writers.each do |coder|
            assert_equal %({"at":"2026-10-13"}), IOStreams::Tabular::Parser::Json.generate(any.render(record, :json), coder)
          end
          assert_equal BigDecimal("12.5"), any.render(BigDecimal("12.5"), :typed)
        end
      end

      describe "required" do
        it "raises for no value: nil, or empty text, as Frictionless does, when reading and writing" do
          %w[any string integer date].each do |type|
            required = field(type: type, constraints: {required: true})

            error = assert_raises(IOStreams::Errors::InvalidValue) { required.cast(nil) }
            assert_equal 'Field "value" is required, but has no value', error.message
            assert_raises(IOStreams::Errors::InvalidValue) { required.cast("") }
            assert_raises(IOStreams::Errors::InvalidValue) { required.render(nil, :text) }
          end
        end

        it "takes text that is only spaces as a value, which a string keeps, and any other type raises for" do
          error = assert_raises(IOStreams::Errors::InvalidValue) { field(type: "integer", constraints: {required: true}).cast("  ") }
          assert_equal 'Field "value": "  " is not a valid integer', error.message
          assert_equal "  ", field(type: "string", constraints: {required: true}).cast("  ")
          assert_equal "  ", field(constraints: {required: true}).cast("  ")
        end

        it "accepts a value" do
          assert_equal 0, field(type: "integer", constraints: {required: true}).cast("0")
          refute field(type: "boolean", constraints: {required: true}).cast("false")
          assert_equal "x", field(constraints: {required: true}).cast("x")
        end

        it "accepts no value for a field that is not required" do
          assert_nil field(type: "integer").cast("")
          assert_nil field(type: "string").cast("")
          assert_nil field.cast(nil)
        end

        it "accepts no value for a required field that allows blank values, when reading and writing" do
          %w[any string integer date].each do |type|
            blank = field(type: type, constraints: {required: true}, allowBlank: true)

            assert_nil blank.cast(nil)
            assert_nil blank.render(nil, :text)
          end
          assert_nil field(type: "string", constraints: {required: true}, allowBlank: true).cast("")
          assert_equal "  ", field(type: "string", constraints: {required: true}, allowBlank: true).cast("  ")
          assert_raises(IOStreams::Errors::InvalidValue) do
            field(type: "integer", constraints: {required: true}, allowBlank: true).cast("  ")
          end
        end
      end
    end
  end
end
