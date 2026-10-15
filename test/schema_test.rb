# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
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

      it "raises for an unknown property of the schema" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [], widht: 3) }
        assert_equal 'Unknown schema property: "widht"', error.message
      end

      it "raises for a property of Frictionless that is not supported, rather than ignore its rule" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [{name: "id"}], primaryKey: ["id"]) }
        assert_equal 'The schema property "primaryKey" is not supported', error.message
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

      it "raises for fields with the same name" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [{name: "id"}, {name: :id}]) }
        assert_equal "Field names must be unique: id", error.message
      end

      it "raises for an unknown property of a field" do
        error = assert_raises(ArgumentError) { field(widht: 3) }
        assert_equal 'Field "value": unknown property "widht"', error.message
      end

      it "raises for a property of Frictionless that is not supported, rather than ignore its check" do
        error = assert_raises(ArgumentError) { field(missingValues: ["-"]) }
        assert_equal 'Field "value": the property "missingValues" is not supported', error.message
      end

      it "accepts the required constraint" do
        assert_predicate field(constraints: {required: true}), :required?
        assert_predicate field("constraints" => {"required" => true}), :required?
        refute_predicate field(constraints: {required: false}), :required?
        refute_predicate field(constraints: {}), :required?
        refute_predicate field, :required?
      end

      it "raises for the constraints of Frictionless that are not supported, and unknown ones" do
        error = assert_raises(ArgumentError) { field(constraints: {required: true, maxLength: 5}) }
        assert_equal 'Field "value": the constraint "maxLength" is not supported', error.message

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
        assert_equal 'Field "value": "decimals" only applies to a number field', error.message
      end

      it "raises for a type of Frictionless that is not supported" do
        error = assert_raises(ArgumentError) { field(type: "time") }
        assert_equal 'Field "value": the type "time" is not supported', error.message
      end

      it "raises for an unknown type" do
        error = assert_raises(ArgumentError) { field(type: "money") }
        assert_equal 'Field "value": unknown type "money"', error.message
      end

      it "raises for a format of a string" do
        assert_raises(ArgumentError) { field(type: "string", format: "email") }
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

    describe ".from_layout" do
      let(:layout) { [{size: 10, key: :name}, {size: 2}, {size: 5, key: :zip, type: :integer}] }

      # The test helper fails a test that causes an IOStreams deprecation warning, which #format_options reports.
      it "returns the schema of the layout as a Hash, without a deprecation warning" do
        expected = {
          fields:      [{name: :name, type: "string", width: 10, truncate: true}, {name: :zip, type: "integer", width: 5, start: 13}],
          fieldsMatch: "subset"
        }

        assert_equal expected, IOStreams::Schema.from_layout(layout: layout)
      end

      it "is the schema that the path of the layout has" do
        path = assert_deprecated(/format_options/) { IOStreams.stream(StringIO.new).format_options(layout: layout, truncate: false) }

        assert_equal path.schema, IOStreams::Schema.from_layout(layout: layout, truncate: false)
      end

      it "translates a layout read from JSON" do
        layout = JSON.parse('[{"size": 10, "key": "name"}, {"size": 5, "key": "zip", "type": "integer"}]')
        path   = IOStreams.stream(StringIO.new("Jack      01234\n")).format(:fixed).schema(IOStreams::Schema.from_layout(layout: layout))

        records = []
        path.each(:hash) { |record| records << record }

        assert_equal [{"name" => "Jack", "zip" => 1234}], records
      end

      it "raises for an invalid layout" do
        assert_raises(IOStreams::Errors::InvalidLayout) { IOStreams::Schema.from_layout(layout: [{key: "id"}]) }
        assert_raises(ArgumentError) { IOStreams::Schema.from_layout(layout: [{size: 2, key: "id", bogus: 1}]) }
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

          path.write(JSON.generate(fields: [{name: "id", type: "time"}]))
          error = assert_raises(ArgumentError) { IOStreams::Schema.read(path.to_s) }
          assert_match(/people\.json: Field "id": the type "time" is not supported\z/, error.message)
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
        assert_equal "The values of a row do not match the schema: 1 value after the last field, which a schema with " \
                     "header: false does not accept, since its columns are the fields in order", error.message
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
        assert_equal 'A schema with header: false has the fields in order, so fieldsMatch must be "exact": "equal"', error.message

        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [], header: false).check_fields_in_order }
        assert_equal "A schema with header: false needs fields, which are the columns of the file", error.message
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
      describe "string" do
        let(:string) { field(type: "string") }

        it "keeps text as it is" do
          assert_equal " Jack ", string.cast(" Jack ")
          assert_equal "", string.cast("")
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
          assert_nil integer.cast("   ")
          assert_nil integer.cast(nil)
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
          assert_equal({"a" => IOStreams::Schema::JsonNumber.new("1.0")}, IOStreams::Schema::Field.any_json({"a" => JSON::Fragment.new("1.0")}))
          assert_equal %({"a":12.50}), IOStreams::Schema::Field.any_json({"a" => JSON::Fragment.new("12.50")}).to_json
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

        it "renders a JSON number that is not finite as a Float, which JSON cannot hold" do
          assert_predicate number.render("NaN", :json), :nan?
          assert_equal Float::INFINITY, number.render("INF", :json)
          assert_predicate field(type: "number", decimals: 0).render("NaN", :json), :nan?
          assert_raises(JSON::GeneratorError) { json(field(type: "number", decimals: 2), "NaN") }
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
          ["yes", "t", 1].each do |value|
            assert_raises(IOStreams::Errors::InvalidValue, value.inspect) { boolean.cast(value) }
          end
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

        it "converts a Date or a Time" do
          assert_equal Date.new(2026, 10, 13), date.cast(DateTime.new(2026, 10, 13, 9, 30))
          assert_equal Date.new(2026, 10, 13), date.cast(Time.new(2026, 10, 13, 9, 30))
        end

        it "reads and writes the format" do
          pattern = field(type: "date", format: "%d/%m/%Y")

          assert_equal Date.new(2026, 10, 13), pattern.cast("13/10/2026")
          assert_raises(IOStreams::Errors::InvalidValue) { pattern.cast("13/10/2026 extra") }
          assert_equal "13/10/2026", pattern.render(Date.new(2026, 10, 13), :text)
          assert_equal "13/10/2026", pattern.render(Date.new(2026, 10, 13), :json)
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
          ["2026-10-13", "2026-10-13 09:30:00", "2026-10-13T25:00:00Z"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { datetime.cast(text) }
          end
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

        it "reads and writes the format" do
          pattern = field(type: "datetime", format: "%Y%m%d%H%M%S%z")

          assert_equal Time.utc(2026, 10, 13, 9, 30), pattern.cast("20261013093000+0000")
          assert_equal "20261013093000+0000", pattern.render(Time.utc(2026, 10, 13, 9, 30), :text)
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
          assert_equal({"at" => "2026-10-13"}, any.render({"at" => Date.new(2026, 10, 13)}, :json))
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

        it "raises for text that is only spaces, for a type that removes them" do
          assert_raises(IOStreams::Errors::InvalidValue) { field(type: "integer", constraints: {required: true}).cast("  ") }
          assert_equal "  ", field(type: "string", constraints: {required: true}).cast("  ")
        end

        it "accepts a value" do
          assert_equal 0, field(type: "integer", constraints: {required: true}).cast("0")
          refute field(type: "boolean", constraints: {required: true}).cast("false")
          assert_equal "x", field(constraints: {required: true}).cast("x")
        end

        it "accepts no value for a field that is not required" do
          assert_nil field(type: "integer").cast("")
          assert_equal "", field(type: "string").cast("")
          assert_nil field.cast(nil)
        end

        it "accepts no value for a required field that allows blank values, when reading and writing" do
          %w[any string integer date].each do |type|
            blank = field(type: type, constraints: {required: true}, allowBlank: true)

            assert_nil blank.cast(nil)
            assert_nil blank.render(nil, :text)
          end
          assert_equal "", field(type: "string", constraints: {required: true}, allowBlank: true).cast("")
          assert_nil field(type: "integer", constraints: {required: true}, allowBlank: true).cast("  ")
        end
      end
    end
  end
end
