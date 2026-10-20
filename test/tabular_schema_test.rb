# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "json"

# IOStreams::Tabular chooses how the columns of a file map to its rows and records when it is created: by the fields of a
# schema, see IOStreams::Tabular::SchemaMapping, or without one as before, see IOStreams::Tabular::HeaderMapping.
class TabularSchemaTest < Minitest::Test
  describe IOStreams::Tabular do
    describe "#mapping" do
      it "maps the columns by the header without a schema, and by the fields of a schema" do
        assert_instance_of IOStreams::Tabular::HeaderMapping, IOStreams::Tabular.new(format: :csv).mapping
        assert_instance_of IOStreams::Tabular::SchemaMapping,
                           IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(fields: [{name: "id"}])).mapping
      end
    end

    describe "the parsers" do
      it "answer whether each row of their format is a record whose keys name its values, and the form of its values" do
        formats = %i[csv psv array json hash fixed]
        keyed   = formats.to_h { |format| [format, IOStreams::Tabular.parser_class(format).keyed?] }
        forms   = formats.to_h { |format| [format, IOStreams::Tabular.parser_class(format).value_form] }

        assert_equal({csv: false, psv: false, array: false, json: true, hash: true, fixed: false}, keyed)
        assert_equal({csv: :text, psv: :text, array: :typed, json: :json, hash: :typed, fixed: :text}, forms)
      end

      it "are the parsers of the format with a schema, except for fixed width and JSON, whose lines depend on it" do
        schema = IOStreams::Schema.new(fields: [{name: "id", width: 2}])
        parsers = %i[csv psv array json hash fixed].to_h { |format| [format, IOStreams::Tabular.new(format: format, schema: schema).parser.class] }

        assert_equal(
          {
            csv:   IOStreams::Tabular::Parser::Csv,
            psv:   IOStreams::Tabular::Parser::Psv,
            array: IOStreams::Tabular::Parser::Array,
            json:  IOStreams::Tabular::Parser::JsonFields,
            hash:  IOStreams::Tabular::Parser::Hash,
            fixed: IOStreams::Tabular::Parser::FixedFields
          },
          parsers
        )
      end

      it "return a row that is already parsed as it is, with a schema" do
        schema = IOStreams::Schema.new(fields: [{name: "id", width: 2}, {name: "code", width: 4}])
        row    = %w[07 abc]

        %i[csv psv array json fixed].each do |format|
          assert_same row, IOStreams::Tabular.new(format: format, schema: schema).parser.parse(row), format.inspect
        end
        assert_equal %w[07 ab], IOStreams::Tabular.new(format: :fixed, schema: schema).parser.parse("07ab  ")
      end

      it "parse each line of JSON with a schema into a record, or nil for null, and raise for a line that is not an object" do
        json = IOStreams::Tabular.new(format: :json, schema: IOStreams::Schema.new(fields: [{name: "a"}])).parser

        assert_equal({"a" => 1}, json.parse(%({"a":1})))
        assert_nil json.parse("null")
        ["[1,2]", "5", "true", %("x")].each do |line|
          error = assert_raises(IOStreams::Errors::TypeMismatch, line) { json.parse(line) }
          assert_match(/\AEach line of the :json format must be an object, whose keys name its values, rather than /, error.message)
        end
        decimals = IOStreams::Tabular.new(format: :json, schema: IOStreams::Schema.new(fields: [{name: "a", type: "number"}])).parser

        assert_raises(IOStreams::Errors::TypeMismatch) { decimals.parse("[1.5]") }
      end
    end

    describe "with a schema" do
      let(:schema) { IOStreams::Schema.new(fields: [{name: "id", type: "integer"}, {name: "pay", type: "number", decimals: 2}]) }

      it "writes a Hash or an Array in a fixed width any field as JSON" do
        schema = IOStreams::Schema.new(fields: [{name: "prefs", width: 12}, {name: "list", width: 7}])

        assert_equal %({"a":[1,2]} [1,"x"]), IOStreams::Tabular.new(format: :fixed, schema: schema).render(
          {"prefs" => {"a" => [1, 2]}, "list" => [1, "x"]}
        )
      end

      # Returns [Array] the lines that rendering the rows yields, see IOStreams::Tabular#render_row.
      def rendered_rows(tabular, *rows)
        lines = []
        rows.each { |row| tabular.render_row(row) { |line| lines << line } }
        lines
      end

      it "converts the values of each record, of every format, by the names of its fields" do
        csv = IOStreams::Tabular.new(format: :csv, schema: schema)

        assert_equal %w[id pay], csv.read_header("ID,Pay")
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, csv.record_parse("1,2.5"))
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, IOStreams::Tabular.new(format: :json, schema: schema).record_parse(%({"Id":1,"pay":2.5})))
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, IOStreams::Tabular.new(format: :hash, schema: schema).record_parse({:id => "1", "PAY" => "2.5"}))
      end

      it "renders each value in the form of the format, in the order of the fields" do
        assert_equal "1,2.50", IOStreams::Tabular.new(format: :csv, schema: schema).render({"pay" => 2.5, "id" => "1"})
        assert_equal %({"id":1,"pay":2.50}), IOStreams::Tabular.new(format: :json, schema: schema).render({"pay" => "2.5", "id" => "1"})
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, IOStreams::Tabular.new(format: :hash, schema: schema).render({"id" => "1", "pay" => "2.5"}))
      end

      it "raises for a line of a format whose rows supply their own keys that is not a record" do
        json = IOStreams::Tabular.new(format: :json, schema: schema)

        ["[1,2.5]", "5", "false", %("x")].each do |line|
          error = assert_raises(IOStreams::Errors::TypeMismatch, line) { json.record_parse(line) }
          assert_match(/\AEach line of the :json format must be an object/, error.message)
          assert_raises(IOStreams::Errors::TypeMismatch, line) { json.row_parse(line) }
        end
      end

      it "reads a JSON line of null, or of a record without keys, as nil, as a blank line is" do
        json = IOStreams::Tabular.new(format: :json, schema: schema)

        %w[null {}].each do |line|
          assert_nil json.row_parse(line), line
          assert_nil json.record_parse(line), line
        end
      end

      it "reads the row of a record as the value of every field, in order, nil for a key that it does not have" do
        superset = IOStreams::Schema.new(fields: schema.fields.map { |field| {name: field.name, type: field.type} }, fieldsMatch: "superset")
        json     = IOStreams::Tabular.new(format: :json, schema: superset)

        refute_predicate json, :header?
        assert_equal [nil, 2], json.row_parse(%({"Pay":2}))
        assert_equal [1, 2], json.row_parse(%({"pay":2,"id":1}))
        assert_equal %w[id pay], json.headerless_columns
        assert_equal [nil, 2], IOStreams::Tabular.new(format: :hash, schema: superset).row_parse({pay: 2})
      end

      it "reads the record of a row already read, whose values are the fields in order, as Rocket Job's workers do" do
        %i[json hash].each do |format|
          tabular = IOStreams::Tabular.new(format: format, schema: schema)

          assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, tabular.record_parse([1, "2.5"]), format.inspect)
        end
      end

      it "renders the names of the fields as the header row, rather than take the keys of the first record" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema)
        lines   = []
        tabular.start_records { |line| lines << line }
        tabular.render_record({"pay" => 2.5, "id" => 1}) { |line| lines << line }

        assert_equal ["id,pay", "1,2.50"], lines
        assert_equal "id,pay", tabular.render_header
      end

      it "writes the header row of the fields before the rows, each of which is the values of the fields, in order" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema)
        lines   = []
        tabular.start_rows { |line| lines << line }

        assert_equal ["id,pay"], lines
        assert_equal ["1,2.50"], rendered_rows(tabular, [1, 2.5])
      end

      it "takes a header row written as the columns of the rows after it, whose columns it matches to the fields" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema)
        lines   = []
        tabular.render_header_row(%w[Pay ID]) { |line| lines << line }

        assert_empty lines
        assert_equal ["1,2.50"], rendered_rows(tabular, [2.5, 1])
      end

      it "writes no value for a field that the header row written does not have" do
        superset = IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(fields: schema.fields.map { |field| {name: field.name} }, fieldsMatch: "superset"))
        superset.render_header_row(%w[pay])

        assert_equal ",2.5", superset.render([2.5])
      end

      it "raises for a column of the header row written that is not a field, unless fieldsMatch skips it" do
        error = assert_raises(IOStreams::Errors::InvalidHeader) { IOStreams::Tabular.new(format: :csv, schema: schema).render_header_row(%w[id pay zip]) }
        assert_match(/\AThe header row does not match the schema: the column "zip" is not a field/, error.message)

        subset = IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(fields: [{name: "id"}], fieldsMatch: "subset"))
        subset.render_header_row(%w[zip id])

        assert_equal "1", subset.render(["12345", 1])
      end

      it "takes no header row from the rows written to a file without one, whose rows are the fields in order" do
        assert_equal [%({"id":1,"pay":2.50})], rendered_rows(IOStreams::Tabular.new(format: :json, schema: schema), [1, 2.5])
        assert_equal ["7"], rendered_rows(IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(fields: [{name: "id"}], header: false)), ["7"])
        assert_equal ["7 "], rendered_rows(IOStreams::Tabular.new(format: :fixed, schema: IOStreams::Schema.new(fields: [{name: "id", width: 2}])), ["7"])

        csv = IOStreams::Tabular.new(format: :csv)

        assert_equal ["a,b"], rendered_rows(csv, %w[a b])
        assert_equal %w[a b], csv.header.columns
      end

      it "converts the values of a row in the order of the fields" do
        array = IOStreams::Tabular.new(format: :array, schema: IOStreams::Schema.new(fields: schema.fields.map { |field| {name: field.name} }, fieldsMatch: "equal"))

        assert_equal %w[id pay], array.read_header(%w[pay id])
        assert_equal %w[1 2.5], array.row_parse(%w[2.5 1])
      end

      it "raises for the options of the header, since the schema describes the columns" do
        %i[columns allowed_columns required_columns].each do |name|
          error = assert_raises(ArgumentError) { IOStreams::Tabular.new(format: :csv, schema: schema, name => ["id"]) }
          assert_match(/\A#{name}: cannot be supplied with a schema/, error.message)
        end
        error = assert_raises(ArgumentError) { IOStreams::Tabular.new(format: :csv, schema: schema, allowed_columns: ["id"], skip_unknown: true) }
        assert_match(/\Aallowed_columns: cannot be supplied with a schema/, error.message)
      end

      it "accepts the options of the header when they are nil, as Rocket Job supplies them" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema, columns: nil, allowed_columns: nil, required_columns: nil, skip_unknown: nil)

        assert_equal "id,pay", tabular.render_header
      end

      it "accepts skip_unknown without allowed_columns, which it only applies to, as Rocket Job supplies it" do
        [true, false].each do |skip_unknown|
          tabular = IOStreams::Tabular.new(format: :csv, schema: schema, columns: nil, allowed_columns: nil, required_columns: nil, skip_unknown: skip_unknown)

          assert_equal %w[id pay], tabular.read_header("id,pay")
          assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, tabular.record_parse("1,2.5"))
        end
      end

      it "raises for an unknown option as an unknown keyword, with or without a schema" do
        [{schema: schema}, {}].each do |options|
          error = assert_raises(ArgumentError) { IOStreams::Tabular.new(format: :csv, delimitr: "\n", **options) }
          assert_equal "unknown keyword: :delimitr", error.message
        end
      end

      it "keeps the header row as read, so that another Tabular can match the same columns, as Rocket Job's workers do" do
        uploader = IOStreams::Tabular.new(format: :csv, schema: schema)

        assert_equal %w[id pay], uploader.read_header("ID,Pay")
        assert_equal %w[ID Pay], uploader.header.columns

        worker = IOStreams::Tabular.new(format: :csv, schema: schema)
        worker.read_header(uploader.header.columns)

        refute_predicate worker, :header?
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, worker.record_parse("1,2.5"))
      end

      it "matches the columns of a header row that is parsed, so that the records after it can be parsed" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema)
        records = []
        ["ID,Pay", "1,2.5", "2,3"].each { |line| tabular.header? ? tabular.parse_header(line) : records << tabular.record_parse(line) }

        assert_equal [{"id" => 1, "pay" => BigDecimal("2.5")}, {"id" => 2, "pay" => BigDecimal("3")}], records
        assert_equal %w[ID Pay], tabular.header.columns
        assert_equal "1,2.50", tabular.render([1, 2.5])
      end

      it "raises for a header row that does not match the schema when it is parsed" do
        assert_raises(IOStreams::Errors::InvalidHeader) { IOStreams::Tabular.new(format: :csv, schema: schema).parse_header("id,name") }
      end

      it "raises for a value after the last column of a row read, unless it is blank, or fieldsMatch skips it" do
        csv = IOStreams::Tabular.new(format: :csv, schema: schema)
        csv.read_header("id,pay")

        error = assert_raises(IOStreams::Errors::InvalidHeader) { csv.record_parse("1,2.5,3") }
        assert_match(/\AThe values of a row do not match the schema: 1 value after the last column/, error.message)
        assert_raises(IOStreams::Errors::InvalidHeader) { csv.row_parse("1,2.5,3") }
        assert_equal({"id" => 1, "pay" => BigDecimal("2.5")}, csv.record_parse("1,2.5,,"))

        subset = IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(fields: [{name: "id", type: "integer"}], fieldsMatch: "subset"))
        subset.read_header("id")

        assert_equal({"id" => 1}, subset.record_parse("1,2.5,3"))
      end

      it "takes only nil and blank text after the last column for no value, so that false raises, as it does when written" do
        array = IOStreams::Tabular.new(format: :array, schema: schema)
        array.read_header(%w[id pay])

        assert_equal [1, BigDecimal("2.5")], array.row_parse([1, "2.5", nil, " "])
        [false, [], 0].each do |value|
          assert_raises(IOStreams::Errors::InvalidHeader, value.inspect) { array.row_parse([1, "2.5", value]) }
        end
      end

      it "raises for a row written that is neither a Hash nor an Array, rather than write its characters" do
        [IOStreams::Tabular.new(format: :csv, schema: schema), IOStreams::Tabular.new(format: :json, schema: schema)].each do |tabular|
          ["N9", :ab, 42, 3.5].each do |row|
            error = assert_raises(IOStreams::Errors::TypeMismatch, row.inspect) { tabular.render(row) }
            assert_match(/\ADon't know how to write a #{row.class.name} with a schema/, error.message)
          end
        end
      end

      it "raises for a blank row written when a field is required, since it has no value for it" do
        required = IOStreams::Schema.new(fields: [{name: "name", constraints: {required: true}}, {name: "age", type: "integer"}])

        %i[csv json psv].each do |format|
          tabular = IOStreams::Tabular.new(format: format, schema: required)
          [{}, []].each do |row|
            error = assert_raises(IOStreams::Errors::InvalidValue, "#{format} #{row.inspect}") { tabular.render(row) }
            assert_equal 'Field "name" is required, but has no value', error.message
          end
        end

        assert_nil IOStreams::Tabular.new(format: :csv, schema: schema).render({})
      end

      it "renders the records written after one that it rejects with a plan of their own keys" do
        required = IOStreams::Schema.new(fields: [{name: "b", type: "integer", constraints: {required: true}}, {name: "a"}])
        tabular  = IOStreams::Tabular.new(format: :csv, schema: required)

        assert_raises(IOStreams::Errors::InvalidValue) { tabular.render({"a" => 1}) }
        assert_equal "2,", tabular.render({"b" => 2})
        assert_equal "7,", tabular.render({"b" => 7})
        assert_raises(IOStreams::Errors::InvalidHeader) { tabular.render({"c" => 9}) }
        assert_equal "3,4", tabular.render({"a" => 4, "b" => 3})
      end

      it "takes the value of each key as a Hash does, rather than that of a key that is only equal to it" do
        hash = IOStreams::Tabular.new(format: :hash, schema: IOStreams::Schema.new(fields: [{name: "1"}]))

        assert_equal({"1" => "x"}, hash.record_parse({1 => "x"}))
        assert_raises(IOStreams::Errors::InvalidHeader) { hash.record_parse({1.0 => "y"}) }
      end

      it "returns a header row whose names are its own, so that changing them does not change the schema" do
        csv = IOStreams::Tabular.new(format: :csv, schema: IOStreams::Schema.new(JSON.parse(%({"fields":[{"name":"id"},{"name":"name"}]}))))
        csv.read_header("id,name").each(&:upcase!)

        assert_equal({"id" => "1", "name" => "Jack"}, csv.record_parse("1,Jack"))
      end

      it "raises for cleansing the header row, whose columns are matched to the fields instead" do
        tabular = IOStreams::Tabular.new(format: :csv, schema: schema)

        assert_equal %w[id pay], tabular.read_header("ID,Pay")
        [true, false, nil, IOStreams::Tabular::CLEANSE_BY_DEFAULT].each do |cleanse|
          error = assert_raises(ArgumentError, cleanse.inspect) { IOStreams::Tabular.new(format: :csv, schema: schema, cleanse_header: cleanse) }
          assert_match(/\Acleanse_header: cannot be supplied with a schema/, error.message)
        end
        assert_raises(ArgumentError) { tabular.read_header("id,pay", cleanse: false) }
        [true, false, nil].each do |cleanse|
          error = assert_raises(ArgumentError, cleanse.inspect) { tabular.read_row("1,2", cleanse: cleanse) { |row| row } }
          assert_match(/\Acleanse_header: cannot be supplied with a schema/, error.message)
          assert_raises(ArgumentError, cleanse.inspect) { tabular.read_record_line("1,2", cleanse: cleanse) { |row| row } }
          assert_raises(ArgumentError, cleanse.inspect) { tabular.restrict_columns(cleanse: cleanse) }
        end
      end

      it "raises for the columns before cleanse_header, with a schema" do
        error = assert_raises(ArgumentError) { IOStreams::Tabular.new(format: :csv, schema: schema, columns: %w[id], cleanse_header: true) }
        assert_match(/\Acolumns: cannot be supplied with a schema/, error.message)
      end

      it "reads a fixed width row as the values of the fields in order, and the record of a row already read, as Rocket Job's workers do" do
        fixed = IOStreams::Tabular.new(format: :fixed, schema: IOStreams::Schema.new(fields: [{name: "name", width: 4}, {name: :age, type: "integer", width: 2}]))

        refute_predicate fixed, :header?
        assert_equal ["Jack", 21], fixed.row_parse("Jack21")
        assert_equal ["name", :age], fixed.headerless_columns
        assert_equal({"name" => "Jack", :age => 21}, fixed.record_parse(["Jack", 21]))
        assert_equal({"name" => "Jack", :age => 21}, fixed.record_parse("Jack21"))
        assert_equal "Jack21", fixed.render(["Jack", 21])
      end
    end
  end
end
