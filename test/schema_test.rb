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
        error = assert_raises(ArgumentError) { field(constraints: {required: true}) }
        assert_equal 'Field "value": the property "constraints" is not supported', error.message
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

      it "accepts a width of remainder" do
        assert_equal :remainder, field(width: "remainder").width
        assert_equal :remainder, IOStreams::Schema.new(fields: [], width: "remainder").width
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

    describe "#field" do
      let(:schema) { IOStreams::Schema.new(fields: [{name: "first_name"}, {name: :age}, {name: "Zip Code"}]) }

      it "finds the field with the same name, whether it is a String or a Symbol" do
        assert_equal "first_name", schema.field("first_name").name
        assert_equal "first_name", schema.field(:first_name).name
        assert_equal :age, schema.field("age").name
      end

      it "finds the field whose name is the same once both are cleansed" do
        assert_equal "first_name", schema.field("First Name").name
        assert_equal "Zip Code", schema.field("zip_code").name
      end

      it "returns nil when no field applies" do
        assert_nil schema.field("last_name")
        assert_nil schema.field(nil)
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
          ["abc", "12-", "1,234", "1.5", "0x1A", "1_000"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { integer.cast(text) }
          end
          assert_raises(IOStreams::Errors::InvalidValue) { integer.cast(1.5) }
          assert_raises(IOStreams::Errors::InvalidValue) { integer.cast(true) }
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

        it "renders a JSON number as a Float" do
          assert_in_delta 12.5, number.render("12.50", :json)
          assert_kind_of Float, number.render("12.50", :json)
          assert_equal BigDecimal("12.5"), number.render("12.50", :typed)
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
        end

        it "raises for a date without a time, or another form" do
          ["2026-10-13", "2026-10-13 09:30:00", "2026-10-13T25:00:00Z"].each do |text|
            assert_raises(IOStreams::Errors::InvalidValue, text) { datetime.cast(text) }
          end
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
      end

      describe "any" do
        it "returns the value as it is" do
          any = field

          assert_equal " 12 ", any.cast(" 12 ")
          assert_equal [1], any.render([1], :json)
          assert_equal "12", any.render(12, :text)
        end
      end
    end
  end
end
