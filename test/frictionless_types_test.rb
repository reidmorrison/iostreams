# frozen_string_literal: true

require_relative "test_helper"

# The list, year, yearmonth and geopoint types of Frictionless, and how each format writes them.
class FrictionlessTypesTest < Minitest::Test
  describe "the types of Frictionless" do
    let(:dir) { Dir.mktmpdir("iostreams") }

    after { FileUtils.rm_rf(dir) }

    # Returns [IOStreams::Schema::Field] a field of the supplied properties.
    def field(**properties)
      IOStreams::Schema.new(fields: [{name: "value", **properties}]).fields.first
    end

    # Returns [String] the text of the records written to the file name with the schema.
    def write(file_name, schema, records)
      path = IOStreams.path(dir, file_name).schema(schema)
      path.writer(:hash) do |io|
        records.each { |record| io << record }
      end
      path
    end

    # Returns [Array<Array>] the rows read from the path.
    def read_rows(path)
      rows = []
      path.each(:array) { |row| rows << row }
      rows
    end

    # Returns [Array<Hash>] the records read from the path.
    def read(path)
      records = []
      path.each(:hash) { |record| records << record }
      records
    end

    describe "list" do
      let(:list) { field(type: "list", itemType: "integer") }

      it "reads the items separated by its delimiter, each in the default form of its itemType" do
        assert_equal [1, 2, 3], list.cast("1,2,3")
        assert_equal [1, nil, 2], list.cast("1,,2")
        assert_equal ["a", " b"], field(type: "list").cast("a, b")
        assert_equal %w[a b], field(type: "list", delimiter: "; ").cast("a; b")
        assert_equal ["a", nil, "b"], field(type: "list", delimiter: " ").cast(" a  b")
        assert_equal %w[a b], field(type: "list", delimiter: ".").cast("a.b")
        assert_equal [Date.new(2026, 1, 2)], field(type: "list", itemType: "date").cast("2026-01-02")
        assert_equal [true, false], field(type: "list", itemType: "boolean").cast("true,false")
        assert_equal [BigDecimal("1.5")], field(type: "list", itemType: "number").cast("1.5")
      end

      it "reads an Array, while the text of a JSON array is delimited text, like any other" do
        assert_equal [1, 2], list.cast([1, "2"])
        assert_equal ['["a', 'b"]'], field(type: "list").cast('["a,b"]')
        assert_raises(IOStreams::Errors::InvalidValue) { list.cast("[1,2]") }
      end

      it "raises for an item that is not of its itemType, naming the list and the type of its items" do
        error = assert_raises(IOStreams::Errors::InvalidValue) { list.cast("1,x") }
        assert_equal 'Field "value": "1,x" is not a valid list of integer items', error.message
        assert_raises(IOStreams::Errors::InvalidValue) { list.cast("[[1]]") }
        assert_raises(IOStreams::Errors::InvalidValue) { list.cast({"a" => 1}) }
      end

      it "reads a single value that is not text as a list of that one item, which IOStreams adds" do
        assert_equal [5], list.cast(5)
        assert_equal [BigDecimal("1.50")], field(type: "list", itemType: "number", decimals: 2).cast(1.5)
        assert_equal [true], field(type: "list", itemType: "boolean").cast(true)
        assert_equal [Date.new(2026, 1, 2)], field(type: "list", itemType: "date").cast(Date.new(2026, 1, 2))
        assert_equal ["42"], field(type: "list").cast(42)
        assert_raises(IOStreams::Errors::InvalidValue) { list.cast(1.5) }
      end

      it "writes the items separated by its delimiter, as an Array in JSON and the :hash format" do
        assert_equal "1,2", list.render([1, 2], :text)
        assert_equal "2026-01-02;2026-02-03",
                     field(type: "list", itemType: "date", delimiter: ";").render("2026-01-02;2026-02-03", :text)
        assert_equal [1, 2], list.render("1,2", :json)
        assert_equal ["2026-01-02"], field(type: "list", itemType: "date").render("2026-01-02", :json)
        assert_equal [1, 2], list.render("1,2", :typed)
        assert_equal "1,2", list.render([1, 2], :scalar)
      end

      it "raises for writing an item whose text holds the delimiter, which would not read back" do
        error = assert_raises(IOStreams::Errors::InvalidValue) { field(type: "list").render(["a,b", "c"], :text) }
        assert_equal 'Field "value": the item "a,b" holds the delimiter ",", so it would not be read back', error.message
        assert_equal ["a,b", "c"], field(type: "list").render(["a,b", "c"], :json)
      end

      it "takes itemType as a Symbol too" do
        assert_equal [1], field(type: "list", itemType: :integer).cast("1")
      end

      it "counts its items for minLength and maxLength" do
        short = field(type: "list", constraints: {maxLength: 2})

        assert_equal %w[a b], short.cast("a,b")
        assert_raises(IOStreams::Errors::InvalidValue) { short.cast("a,b,c") }
      end

      it "raises for an itemType that is not supported, or a delimiter that is not text" do
        [{itemType: "object"}, {itemType: "list"}, {delimiter: ""}, {delimiter: 1}, {format: "array"}].each do |properties|
          assert_raises(ArgumentError, properties.inspect) { field(type: "list", **properties) }
        end
      end

      it "writes each number of a list with its decimals, and rounds each number read to them, half up" do
        numbers = field(type: "list", itemType: "number", decimals: 2)

        assert_equal "1.50,2.25,", numbers.render([BigDecimal("1.5"), BigDecimal("2.25"), nil], :text)
        assert_equal "1.50,2.26", numbers.render([1.5, BigDecimal("2.255")], :text)
        assert_equal [BigDecimal("1.01"), BigDecimal("2.00"), BigDecimal("3")], numbers.cast("1.005,2.004,3")
        assert_equal [BigDecimal("1.50")], numbers.render(["1.5"], :typed)
        assert_equal "[1.50,2.25]", IOStreams::Tabular::Parser::Json.generate(numbers.render([1.5, 2.25], :json))
      end

      it "writes each whole number of a list of numbers without a decimal point, unless it has decimals" do
        numbers = field(type: "list", itemType: "number")
        floats  = field(type: "list", itemType: "number", floatNumber: true)

        assert_equal "42,1.5,3", numbers.render([42, 1.5, BigDecimal("3")], :text)
        assert_equal "42,1.5", floats.render([42.0, 1.5], :text)
        assert_equal "42.00,1.50", field(type: "list", itemType: "number", decimals: 2).render([42, 1.5], :text)
      end

      it "reads each number of a list as a Float with floatNumber" do
        floats = field(type: "list", itemType: "number", floatNumber: true)

        assert_equal [1.5, 2.0], floats.cast("1.5,2")
        assert_equal [Float], floats.cast("1.5,2").map(&:class).uniq
        assert_equal [1.25], field(type: "list", itemType: "number", floatNumber: true, decimals: 2).cast("1.254")
      end

      it "raises for decimals or floatNumber of a list whose items are not numbers, or that are not valid" do
        error = assert_raises(ArgumentError) { field(type: "list", itemType: "integer", decimals: 2) }
        assert_equal 'Field "value": "decimals" only applies to a list whose itemType is "number", not "integer"', error.message
        error = assert_raises(ArgumentError) { field(type: "list", floatNumber: true) }
        assert_equal 'Field "value": "floatNumber" only applies to a list whose itemType is "number", not "string"', error.message
        assert_raises(ArgumentError) { field(type: "list", itemType: "number", decimals: -1) }
        assert_raises(ArgumentError) { field(type: "list", itemType: "number", floatNumber: "yes") }
      end

      it "keeps the decimals of a list of numbers in a contract, which reads its numbers with them" do
        schema   = IOStreams::Schema.new(fields: [{name: "scores", type: "list", itemType: "number", decimals: 2}])
        contract = schema.to_contract

        assert_equal({fields: [{name: "scores", type: "list", itemType: "number", decimals: 2}]}, contract.to_h)
        assert_includes schema.to_dsl("Scores"), %(field :scores, :list, item_type: "number", decimals: 2)
        assert_equal [BigDecimal("1.26")], contract.new(scores: "1.255").scores
      end

      it "gives decimals and floatNumber to the field of its items, which owns them, rather than hold them itself" do
        numbers = field(type: "list", itemType: "number", decimals: 2, floatNumber: true)

        assert_nil numbers.decimals
        refute_predicate numbers, :float?
        assert_equal 2, numbers.item_field.decimals
        assert_predicate numbers.item_field, :float?
        assert_equal({name: "value", type: "list", itemType: "number", decimals: 2, floatNumber: true}, numbers.to_h)
      end
    end

    describe "year" do
      let(:year) { field(type: "year") }

      it "reads text of 4 digits, or a whole number" do
        assert_equal 2026, year.cast("2026")
        assert_equal 2026, year.cast(2026)
        assert_equal 2026, year.cast(2026.0)
        ["26", "20261", "2026.0", "-2026", "x"].each do |text|
          assert_raises(IOStreams::Errors::InvalidValue, text) { year.cast(text) }
        end
        [-1, 10_000, 12_345.0].each do |number|
          assert_raises(IOStreams::Errors::InvalidValue, number.inspect) { year.cast(number) }
        end
        assert_equal 0, year.cast(0)
        assert_equal 9999, year.cast(9999)
      end

      it "writes 4 digits, and an Integer in JSON" do
        assert_equal "0026", year.render(26, :text)
        assert_equal 2026, year.render("2026", :json)
        assert_equal 2026, year.render("2026", :typed)
      end

      it "compares its values for minimum and maximum" do
        recent = field(type: "year", constraints: {minimum: "2000"})

        assert_raises(IOStreams::Errors::InvalidValue) { recent.cast("1999") }
      end
    end

    describe "yearmonth" do
      let(:month) { field(type: "yearmonth") }

      it "reads text of a year and month as the Date on the first of the month" do
        assert_equal Date.new(2026, 10, 1), month.cast("2026-10")
        assert_equal Date.new(2026, 10, 1), month.cast(Date.new(2026, 10, 1))
        assert_equal Date.new(2026, 10, 1), month.cast(Time.utc(2026, 10, 1))
        ["2026-13", "2026-1", "2026-10-02", "2026-13-01", "10/2026"].each do |text|
          assert_raises(IOStreams::Errors::InvalidValue, text) { month.cast(text) }
        end
        assert_raises(IOStreams::Errors::InvalidValue) { month.cast(Date.new(2026, 10, 2)) }
        assert_raises(IOStreams::Errors::InvalidValue) { month.cast(Date.new(10_000, 1, 1)) }
      end

      it "reads the ISO 8601 text of the first of a month, such as the text of a cell of a spreadsheet that holds the date" do
        assert_equal Date.new(2026, 10, 1), month.cast("2026-10-01")
        assert_equal Date.new(2026, 10, 1), month.load("2026-10-01")
      end

      it "writes the year and month, and keeps its Date in the :hash format" do
        assert_equal "2026-10", month.render(Date.new(2026, 10, 1), :text)
        assert_equal "2026-10", month.render("2026-10", :json)
        assert_equal Date.new(2026, 10, 1), month.render("2026-10", :typed)
      end

      it "compares its values for minimum and maximum" do
        assert_raises(IOStreams::Errors::InvalidValue) { field(type: "yearmonth", constraints: {maximum: "2026-06"}).cast("2026-07") }
      end
    end

    describe "geopoint" do
      it "reads the text of its default format as [lon, lat]" do
        point = field(type: "geopoint")

        assert_equal [BigDecimal("90.5"), BigDecimal("45.5")], point.cast("90.50, 45.50")
        assert_equal [BigDecimal("-122.4"), BigDecimal("37.8")], point.cast("-122.4,37.8")
        ["190, 1", "1, 91", "1", "1, 2, 3", "[1, 2]", "a, b"].each do |text|
          assert_raises(IOStreams::Errors::InvalidValue, text) { point.cast(text) }
        end
      end

      it "reads a JSON array, or its text, of the array format, and a JSON object, or its text, of the object format" do
        array  = field(type: "geopoint", format: "array")
        object = field(type: "geopoint", format: "object")

        assert_equal [BigDecimal("90.5"), BigDecimal("45.5")], array.cast("[90.5, 45.5]")
        assert_equal [BigDecimal("90.12345678901234567"), BigDecimal("45.5")], array.cast("[90.12345678901234567, 45.5]")
        assert_equal [BigDecimal("90.5"), BigDecimal("45.5")], array.cast([90.5, 45.5])
        assert_equal [BigDecimal("90.5"), BigDecimal("45.5")], object.cast('{"lon": 90.5, "lat": 45.5}')
        assert_equal [BigDecimal("2"), BigDecimal("1")], object.cast({lat: 1, lon: 2})
        assert_raises(IOStreams::Errors::InvalidValue) { array.cast("90.5, 45.5") }
        assert_raises(IOStreams::Errors::InvalidValue) { object.cast('{"lon": 1}') }
        assert_raises(IOStreams::Errors::InvalidValue) { object.cast('{"lon": 1, "lat": 2, "alt": 3}') }
      end

      it "reads an Array or a Hash whatever its format, of a source of Ruby objects, such as Parquet or a spreadsheet" do
        assert_equal [BigDecimal("1.5"), BigDecimal("2")], field(type: "geopoint").cast(["1.5", 2])
        assert_equal [BigDecimal("1"), BigDecimal("2")], field(type: "geopoint", format: "array").cast({"lon" => 1, "lat" => 2})
      end

      it "writes the form of its format" do
        point  = field(type: "geopoint")
        array  = field(type: "geopoint", format: "array")
        object = field(type: "geopoint", format: "object")

        assert_equal "90.5, 45.5", point.render("90.50,45.50", :text)
        assert_equal "90.5, 45.5", point.render([90.5, 45.5], :json)
        assert_equal "[90.5,45.5]", array.render([90.5, 45.5], :text)
        assert_equal "[90.5,45.5]", JSON.generate(array.render([90.5, 45.5], :json))
        assert_equal %({"lon":90.5,"lat":45.5}), object.render([90.5, 45.5], :text)
        assert_equal %({"lon":90.5,"lat":45.5}), object.render([90.5, 45.5], :scalar)
      end

      it "is the point itself, [lon, lat], in a format whose values are Ruby objects, whatever its format" do
        point = [BigDecimal("90.5"), BigDecimal("45.5")]

        %w[default array object].each do |format|
          assert_equal point, field(type: "geopoint", format: format).render([90.5, 45.5], :typed), format
        end
        assert_equal point, field(type: "geopoint", format: :array).cast([90.5, 45.5])
      end

      it "is written by a contract to a file whose field has any format" do
        contract = IOStreams::Contract.new(fields: [{name: "place", type: "geopoint"}])
        %w[default array object].each do |format|
          path = IOStreams.path(dir, "places.json").schema(fields: [{name: "place", type: "geopoint", format: format}])
          path.as(contract).writer(:hash) { |io| io << {"place" => "1.5, 2"} }

          assert_equal [{"place" => [BigDecimal("1.5"), BigDecimal("2")]}], read(path.as(contract)), format
        end
      end

      it "raises for a format other than default, array or object" do
        error = assert_raises(ArgumentError) { field(type: "geopoint", format: "lonlat") }
        assert_equal 'Field "value": the format "lonlat" is not one of a geopoint, "default", "array", "object"', error.message
      end
    end

    describe "the format of a string" do
      it "checks an email address" do
        email = field(type: "string", format: "email")

        assert_equal "jack@example.org", email.cast("jack@example.org")
        ["jack", "a b@example.org", "jack@", "@example.org"].each do |text|
          error = assert_raises(IOStreams::Errors::InvalidValue, text) { email.cast(text) }
          assert_equal "Field \"value\": #{text.inspect} is not a valid email", error.message
        end
        assert_equal "jack@example.org", email.render("jack@example.org", :text)
      end

      it "checks a URI of RFC 3986 with a scheme" do
        uri = field(type: "string", format: "uri")

        ["https://example.org/a?b=1#c", "mailto:jack@example.org", "urn:isbn:0451450523", "s3://bucket/key.csv"].each do |text|
          assert_equal text, uri.cast(text)
        end
        ["example.org", "/a/b", "http://a b", "://x"].each do |text|
          assert_raises(IOStreams::Errors::InvalidValue, text) { uri.cast(text) }
        end
        assert_equal "https://example.org", uri.cast(URI("https://example.org"))
      end

      it "checks a UUID in any case, returning it unchanged" do
        uuid = field(type: "string", format: "uuid")

        assert_equal "123e4567-e89b-12d3-a456-426614174000", uuid.cast("123e4567-e89b-12d3-a456-426614174000")
        assert_equal "123E4567-E89B-12D3-A456-426614174000", uuid.cast("123E4567-E89B-12D3-A456-426614174000")
        ["123e4567e89b12d3a456426614174000", "123e4567-e89b-12d3-a456-42661417400g", "{123e4567-e89b-12d3-a456-426614174000}"].each do |text|
          assert_raises(IOStreams::Errors::InvalidValue, text) { uuid.cast(text) }
        end
      end

      it "reads binary from its base64 text, or a binary String as it is, and writes its base64 text" do
        binary = field(type: "string", format: "binary")
        bytes  = "\x00\xFFhi".b

        assert_equal bytes, binary.cast("AP9oaQ==")
        assert_equal Encoding::BINARY, binary.cast("AP9oaQ==").encoding
        assert_same bytes, binary.cast(bytes)
        assert_raises(IOStreams::Errors::InvalidValue) { binary.cast("not base64!") }
        assert_raises(IOStreams::Errors::InvalidValue) { binary.cast(5) }
        assert_equal "AP9oaQ==", binary.render(bytes, :text)
        assert_equal "AP9oaQ==", binary.render(bytes, :json)
        assert_equal bytes, binary.render("AP9oaQ==", :typed)
        assert_equal bytes, binary.load(binary.dump(bytes))
        assert_raises(IOStreams::Errors::InvalidValue) { field(type: "string", format: "binary", constraints: {maxLength: 2}).cast(bytes) }
        assert_equal "AP9oaQ==", binary.render(bytes, :scalar)
      end

      it "reads base64 text with whitespace, such as the line breaks of MIME, and raises for text of only whitespace" do
        binary = field(type: "string", format: "binary")

        assert_equal "\x00\xFFhi".b, binary.cast("AP9o\r\naQ==\n")
        assert_equal "\x00\xFFhi".b, binary.cast(" AP9o aQ== ")
        assert_raises(IOStreams::Errors::InvalidValue) { binary.cast("  ") }
        assert_raises(IOStreams::Errors::InvalidValue) { binary.cast("AP9oaQ=") }
      end

      it "reads the base64 text of a format of text even when it is binary text, such as read with encoding BINARY" do
        schema = {fields: [{name: "data", type: "string", format: "binary"}]}
        File.binwrite(File.join(dir, "data.csv"), "data\nAP9oaQ==\n")
        File.binwrite(File.join(dir, "data.json"), %({"data":"AP9oaQ=="}\n))

        assert_equal [{"data" => "\x00\xFFhi".b}], read(IOStreams.path(dir, "data.csv").encoding("BINARY").schema(schema))
        assert_equal [{"data" => "\x00\xFFhi".b}], read(IOStreams.path(dir, "data.json").encoding("BINARY").schema(schema))
        assert_equal "\x00\xFFhi".b, field(type: "string", format: "binary").parse("AP9oaQ==".b, :text)
        assert_equal "AP9oaQ==".b, field(type: "string", format: "binary").parse("AP9oaQ==".b, :typed)
      end

      it "raises for a pattern of bytes, which are not text, and counts their bytes for minLength and maxLength" do
        error = assert_raises(ArgumentError) { field(type: "string", format: "binary", constraints: {pattern: "a+"}) }
        assert_equal 'Field "value": the constraint "pattern" does not apply to bytes, a string with the format "binary", which ' \
                     "are not text", error.message
        assert_equal "abc".b, field(type: "string", format: "binary", constraints: {minLength: 3}).cast("YWJj")
      end

      it "copies the bytes of a Parquet binary column to CSV as their base64 text, which reads back" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        schema = {fields: [{name: "id", type: "integer"}, {name: "data", type: "string", format: "binary"}]}
        record = {"id" => 1, "data" => "\x00\xFFhi".b}
        write("data.parquet", schema, [record])
        IOStreams.path(dir, "data.csv").copy_from(IOStreams.path(dir, "data.parquet"), mode: :hash)

        assert_equal "id,data\n1,AP9oaQ==\n", IOStreams.path(dir, "data.csv").read
        assert_equal [record], read(IOStreams.path(dir, "data.csv").schema(schema))
      end

      it "keeps the format of a string, which says what its values are, in a contract and the schema that a copy takes" do
        schema = IOStreams::Schema.new(
          fields: [
            {name: "data", type: "string", format: "binary"},
            {name: "on", type: "date", format: "%d/%m/%Y"},
            {name: "at", type: "geopoint", format: "array"}
          ]
        )

        assert_equal [{name: "data", type: "string", format: "binary"}, {name: "on", type: "date"}, {name: "at", type: "geopoint"}],
                     schema.without_text.fields.map(&:to_h)
        assert_equal [{name: "data", type: "string", format: "binary"}, {name: "on", type: "date"}, {name: "at", type: "geopoint"}],
                     schema.to_contract.fields.map(&:to_h)
      end

      it "raises for any other format, including any, which Frictionless defines only for dates and times" do
        ["any", "%Y", "url", 5].each do |format|
          assert_raises(ArgumentError, format.inspect) { field(type: "string", format: format) }
        end
        error = assert_raises(ArgumentError) { field(type: "string", format: "any") }
        assert_equal 'Field "value": the format "any" is not supported for a string field, only "email", "uri", "uuid", "binary"',
                     error.message
      end

      it "writes binary to CSV and JSON as base64, to a spreadsheet as base64 text, and to Parquet as bytes, which read back" do
        schema = {fields: [{name: "id", type: "string", format: "uuid"}, {name: "data", type: "string", format: "binary"}]}
        record = {"id" => "123e4567-e89b-12d3-a456-426614174000", "data" => "\x00\xFFhi".b}

        csv = write("data.csv", schema, [record])

        assert_equal "id,data\n123e4567-e89b-12d3-a456-426614174000,AP9oaQ==\n", csv.read
        assert_equal [record], read(csv)
        assert_equal [record], read(write("data.json", schema, [record]))
        assert_equal [record], read(write("data.xlsx", schema, [record]))
        lines = []
        IOStreams.path(dir, "data.xlsx").each(:line) { |line| lines << line }

        assert_equal "123e4567-e89b-12d3-a456-426614174000,AP9oaQ==", lines.last
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        parquet = write("data.parquet", schema, [record])

        assert_equal [record], read(parquet)
        assert_equal({name: "data", type: "string", format: "binary"}, IOStreams.path(dir, "data.parquet").infer_schema.fields.last.to_h)
        assert_equal [{"id" => record["id"], "data" => record["data"]}], read(IOStreams.path(dir, "data.parquet"))
      end
    end

    describe "timeZone" do
      it "reads ISO 8601 text of a datetime without an offset in its zone, also when its clocks change" do
        zone = field(type: "datetime", timeZone: "America/New_York")

        assert_equal Time.new(2026, 7, 1, 9, 30, 0, "-04:00"), zone.cast("2026-07-01T09:30:00")
        assert_equal(-14_400, zone.cast("2026-07-01T09:30:00").utc_offset)
        assert_equal(-18_000, zone.cast("2026-01-01 09:30:00").utc_offset)
        assert_equal Time.utc(2026, 7, 1, 9, 30), zone.cast("2026-07-01T09:30:00Z")
        assert_equal Time.new(2026, 7, 1, 9, 30, 0, "+05:30"), zone.cast("2026-07-01T09:30:00+05:30")
      end

      it "raises for a clock that its zone skips, and reads the first of a clock that it has twice" do
        zone = field(type: "datetime", timeZone: "America/New_York")

        error = assert_raises(IOStreams::Errors::InvalidValue) { zone.cast("2026-03-08T02:30:00") }
        assert_equal 'Field "value": "2026-03-08T02:30:00" is not a valid datetime, since 2026-03-08 02:30:00 is no time in ' \
                     "America/New_York, whose clocks skip it", error.message
        assert_equal(-14_400, zone.cast("2026-11-01T01:30:00").utc_offset)
      end

      it "reads the first of a clock that a zone has twice when it changed its offset for good, rather than raise" do
        assert_equal(14_400, field(type: "datetime", timeZone: "Europe/Moscow").cast("2014-10-26T01:30:00").utc_offset)
        assert_equal(10_800, field(type: "datetime", timeZone: "Europe/Moscow").cast("2014-10-26T02:30:00").utc_offset)
      end

      it "reads the seconds since 1970 of %s and %Q as that time, whatever its zone" do
        assert_equal Time.utc(1970, 1, 1, 0, 0, 10), field(type: "datetime", format: "%s", timeZone: "America/New_York").cast("10")
        assert_equal Time.utc(1970, 1, 1, 0, 0, 1), field(type: "datetime", format: "%Q", timeZone: "America/New_York").cast("1000")
        assert_equal "10", field(type: "datetime", format: "%s", timeZone: "America/New_York").render(Time.utc(1970, 1, 1, 0, 0, 10), :text)
      end

      it "reads text of a format without a zone in its zone, and writes it there, so that it reads back as the same time" do
        zone = field(type: "datetime", format: "%Y-%m-%d %H:%M", timeZone: "America/New_York")
        time = Time.utc(2026, 7, 1, 13, 30)

        assert_equal time, zone.cast("2026-07-01 09:30")
        assert_equal "2026-07-01 09:30", zone.render(time, :text)
        assert_equal time, zone.cast(zone.render(time, :text))
        assert_equal "2026-07-01 13:30 +0000", field(type: "datetime", format: "%Y-%m-%d %H:%M %z", timeZone: "-05:00").render(time, :text)
      end

      it "writes a datetime without a format in ISO 8601 with its offset, as without a zone" do
        assert_equal "2026-07-01T13:30:00Z", field(type: "datetime", timeZone: "America/New_York").render(Time.utc(2026, 7, 1, 13, 30), :text)
      end

      it "takes a fixed offset from UTC, or UTC, the default" do
        assert_equal Time.new(2026, 7, 1, 9, 30, 0, "+05:30"), field(type: "datetime", timeZone: "+05:30").cast("2026-07-01T09:30:00")
        assert_predicate field(type: "datetime", timeZone: "UTC").cast("2026-07-01T09:30:00"), :utc?
        assert_equal(-18_000, field(type: "datetime", timeZone: "-05:00").cast("2026-07-01T09:30:00").utc_offset)
      end

      it "reads a time of day of a summer day, or of Rails, as the clock that its zone shows on that day" do
        clock  = field(type: "time", timeZone: "America/New_York")
        summer = Time.new(2026, 7, 1, 9, 30, 0, "-04:00")

        assert_equal Time.new(2000, 1, 1, 9, 30, 0, "-05:00"), clock.cast(summer)
        assert_equal "09:30:00", clock.render(summer, :text)
        assert_equal "09:30:00", clock.render(Time.utc(2026, 7, 1, 13, 30), :text)
        if defined?(ActiveSupport::TimeWithZone)
          zoned = ActiveSupport::TimeZone["America/New_York"].local(2026, 7, 1, 9, 30)

          assert_equal "09:30:00", clock.render(zoned, :text)
        end
      end

      it "writes the UTC clock of a time with timeZone UTC, and its own clock without a timeZone" do
        time = Time.new(2000, 1, 1, 9, 30, 0, "-05:00")

        assert_equal "14:30:00", field(type: "time", timeZone: "UTC").render(time, :text)
        assert_equal "09:30:00", field(type: "time").render(time, :text)
      end

      it "keeps the clock of a time of day written to Parquet, which reads it back in its zone" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        schema = {fields: [{name: "at", type: "time", timeZone: "America/New_York"}]}
        File.write(File.join(dir, "a.csv"), "at\n09:30:00\n")
        IOStreams.path(dir, "b.parquet").schema(schema).copy_from(IOStreams.path(dir, "a.csv").schema(schema), mode: :hash)
        IOStreams.path(dir, "c.csv").schema(schema).copy_from(IOStreams.path(dir, "b.parquet").schema(schema), mode: :hash)

        assert_equal "at\n09:30:00\n", File.read(File.join(dir, "c.csv"))
        assert_equal [{"at" => Time.new(2000, 1, 1, 9, 30, 0, "-05:00")}], read(IOStreams.path(dir, "b.parquet").schema(schema))
      end

      it "writes the clock of its zone to a spreadsheet's cell, which reads back as the same time" do
        schema = {fields: [{name: "at", type: "datetime", timeZone: "America/New_York"}, {name: "on", type: "time", timeZone: "America/New_York"}]}
        record = {"at" => Time.utc(2026, 7, 1, 13, 30), "on" => Time.new(2000, 1, 1, 9, 30, 0, "-05:00")}
        path   = write("times.xlsx", schema, [record])

        assert_equal [record], read(path)
        assert_equal [{"at" => Time.utc(2026, 7, 1, 9, 30), "on" => Time.utc(2000, 1, 1, 9, 30)}], read(IOStreams.path(dir, "times.xlsx"))
        lines = []
        IOStreams.path(dir, "times.xlsx").each(:line) { |line| lines << line }

        assert_equal "2026-07-01T09:30:00Z,2000-01-01T09:30:00Z", lines.last
      end

      it "reads the clock of a spreadsheet's cell in its zone, and writes the UTC clock without a zone" do
        IOStreams.path(dir, "cells.xlsx").writer(:array) do |io|
          io << %w[at]
          io << [Time.utc(2026, 7, 1, 9, 30)]
          io << [Time.utc(2026, 1, 1, 9, 30)]
        end

        zoned = IOStreams.path(dir, "cells.xlsx").schema(fields: [{name: "at", type: "datetime", timeZone: "America/New_York"}])
        plain = IOStreams.path(dir, "cells.xlsx").schema(fields: [{name: "at", type: "datetime"}])

        assert_equal [{"at" => Time.utc(2026, 7, 1, 13, 30)}, {"at" => Time.utc(2026, 1, 1, 14, 30)}], read(zoned)
        assert_equal [{"at" => Time.utc(2026, 7, 1, 9, 30)}, {"at" => Time.utc(2026, 1, 1, 9, 30)}], read(plain)
        path = write("utc.xlsx", {fields: [{name: "at", type: "datetime"}]}, [{"at" => Time.new(2026, 7, 1, 9, 30, 0, "-04:00")}])

        assert_equal [{"at" => Time.utc(2026, 7, 1, 13, 30)}], read(IOStreams.path(path.to_s))
      end

      it "raises for a spreadsheet's cell whose clock its zone skips" do
        IOStreams.path(dir, "cells.xlsx").writer(:array) do |io|
          io << %w[at]
          io << [Time.utc(2026, 3, 8, 2, 30)]
        end

        error = assert_raises(IOStreams::Errors::InvalidValue) do
          read(IOStreams.path(dir, "cells.xlsx").schema(fields: [{name: "at", type: "datetime", timeZone: "America/New_York"}]))
        end
        assert_equal 'Field "at": 2026-03-08 02:30:00 is not a valid datetime, since 2026-03-08 02:30:00 is no time in ' \
                     "America/New_York, whose clocks skip it, in record 1", error.message
      end

      it "writes the clock of its zone of a winter date to a spreadsheet's cell, which reads back, also through a contract" do
        schema = {fields: [{name: "at", type: "datetime", timeZone: "America/New_York"}]}
        path   = write("winter.xlsx", schema, [{"at" => Time.utc(2026, 12, 1, 14, 30)}])

        assert_equal [{"at" => Time.utc(2026, 12, 1, 9, 30)}], read(IOStreams.path(dir, "winter.xlsx"))
        assert_equal [{"at" => Time.utc(2026, 12, 1, 14, 30)}], read(path)
        assert_equal [{"at" => Time.utc(2026, 12, 1, 14, 30)}], read(IOStreams.path(dir, "winter.xlsx").as(schema))
        assert_equal(-18_000, read(IOStreams.path(dir, "winter.xlsx").as(schema)).first["at"].utc_offset)
      end

      it "writes both times of a clock that its zone has twice as the same cell, which reads back as the first" do
        # 01:30 in New York on 2026-11-01 is 05:30 UTC, at -04:00, and an hour later 06:30 UTC, at -05:00, once its
        # clocks move back. A cell holds the clock alone, so the second reads back as the first, while CSV keeps the offset.
        schema = {fields: [{name: "at", type: "datetime", timeZone: "America/New_York"}]}
        times   = [Time.utc(2026, 11, 1, 5, 30), Time.utc(2026, 11, 1, 6, 30)]
        records = times.map { |time| {"at" => time} }
        cells   = read(write("twice.xlsx", schema, records)).map { |record| record["at"].getutc }
        texts   = read(write("twice.csv", schema, records)).map { |record| record["at"].getutc }

        assert_equal [{"at" => Time.utc(2026, 11, 1, 1, 30)}] * 2, read(IOStreams.path(dir, "twice.xlsx"))
        assert_equal [times.first] * 2, cells
        assert_equal times, texts
      end

      it "is kept by a contract, and by the schema that the target of a copy takes, which writes the clocks of its zone" do
        schema = IOStreams::Schema.new(fields: [{name: "at", type: "datetime", timeZone: "America/New_York"}])

        assert_equal [{name: "at", type: "datetime", timeZone: "America/New_York"}], schema.to_contract.fields.map(&:to_h)
        assert_equal [{name: "at", type: "datetime", timeZone: "America/New_York"}], schema.without_text.fields.map(&:to_h)
        assert_equal [{name: "at", type: "datetime", timeZone: "America/New_York"}],
                     IOStreams::Schema.new(fields: [{name: "at", type: "datetime", format: "%m/%d/%Y %H:%M", timeZone: "America/New_York"}]).
                       without_text.fields.map(&:to_h)
      end

      it "writes the clocks of its zone when a contract's records are copied to a spreadsheet, while CSV keeps their offsets" do
        contract = {fields: [{name: "at", type: "datetime", timeZone: "America/New_York"}]}
        File.write(File.join(dir, "visits.csv"), "at\n2026-07-01 09:30:00\n2026-07-01T13:30:00Z\n")
        source = IOStreams.path(dir, "visits.csv").as(contract)
        IOStreams.path(dir, "visits.xlsx").copy_from(source, mode: :hash)
        IOStreams.path(dir, "copy.csv").copy_from(source, mode: :hash)

        assert_equal [{"at" => Time.utc(2026, 7, 1, 9, 30)}] * 2, read(IOStreams.path(dir, "visits.xlsx"))
        assert_equal [{"at" => Time.utc(2026, 7, 1, 13, 30)}] * 2, read(IOStreams.path(dir, "visits.xlsx").as(contract))
        assert_equal "at\n2026-07-01T09:30:00-04:00\n2026-07-01T13:30:00Z\n", File.read(File.join(dir, "copy.csv"))
      end

      it "writes the clock of its zone to Parquet when a contract's times of day are copied, which reads back the same" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        contract = {fields: [{name: "opens", type: "time", timeZone: "America/New_York"}]}
        File.write(File.join(dir, "shops.csv"), "opens\n09:30:00\n14:30:00Z\n")
        IOStreams.path(dir, "shops.parquet").copy_from(IOStreams.path(dir, "shops.csv").as(contract), mode: :hash)

        assert_equal [{"opens" => Time.utc(2000, 1, 1, 9, 30)}] * 2, read(IOStreams.path(dir, "shops.parquet"))
        assert_equal [{"opens" => Time.new(2000, 1, 1, 9, 30, 0, "-05:00")}] * 2, read(IOStreams.path(dir, "shops.parquet").as(contract))
      end

      it "reads a time of day without an offset in its zone on 2000-01-01, and writes the clock of the zone" do
        clock = field(type: "time", timeZone: "America/New_York")

        assert_equal Time.new(2000, 1, 1, 9, 30, 0, "-05:00"), clock.cast("09:30:00")
        assert_equal "09:30:00", clock.render(Time.utc(2000, 1, 1, 14, 30), :text)
        assert_equal "09:30", field(type: "time", format: "%H:%M", timeZone: "-05:00").render(Time.utc(2000, 1, 1, 14, 30), :text)
        assert_equal Time.new(2000, 1, 1, 9, 30, 0, "-05:00"), field(type: "time", format: "%H:%M", timeZone: "America/New_York").cast("09:30")
      end

      it "raises when the schema is built for a zone that is not one, or a field that is neither a datetime nor a time" do
        [{type: "datetime", timeZone: "Mars/Olympus"}, {type: "datetime", timeZone: "+5"}, {type: "datetime", timeZone: 5},
         {type: "datetime", timeZone: ""}, {type: "date", timeZone: "UTC"}, {type: "datetime", timeZone: "+24:00"},
         {type: "time", timeZone: "-05:60"}].each do |properties|
          assert_raises(ArgumentError, properties.inspect) { field(**properties) }
        end
        error = assert_raises(ArgumentError) { field(type: "datetime", timeZone: "Mars/Olympus") }
        assert_equal 'Field "value": the timeZone "Mars/Olympus" is not a zone of the IANA time zone database, such as ' \
                     '"America/New_York", nor an offset, such as "-05:00"', error.message
        error = assert_raises(ArgumentError) { field(type: "datetime", timeZone: "+24:00") }
        assert_equal 'Field "value": the timeZone "+24:00" is not an offset from UTC, whose hours are at most 23 and minutes ' \
                     "at most 59", error.message
      end

      it "raises ArgumentError naming tzinfo-data for the name of a zone when the system has no IANA time zone database" do
        require "tzinfo"
        TZInfo::Timezone.stub(:get, ->(_name) { raise(TZInfo::DataSourceNotFound, "no source") }) do
          error = assert_raises(ArgumentError) { field(type: "datetime", timeZone: "America/New_York") }
          assert_includes error.message, '`gem "tzinfo-data"`'
        end
      end

      it "raises ArgumentError for the name of a zone when the tzinfo gem is not installed, naming it" do
        script = <<~'RUBY'
          module Kernel
            alias_method :require_installed, :require

            def require(name)
              raise(LoadError, "cannot load such file -- #{name}") if name == "tzinfo"

              require_installed(name)
            end
          end
          require "iostreams"
          print IOStreams::Schema.new(fields: [{name: "at", type: "datetime", timeZone: "-05:00"}]).fields.size
          begin
            IOStreams::Schema.new(fields: [{name: "at", type: "datetime", timeZone: "America/New_York"}])
          rescue ArgumentError => e
            print " ", e.message
          end
        RUBY
        lib     = File.expand_path("../lib", __dir__)
        message = IO.popen([RbConfig.ruby, "-I", lib, "-e", script], err: File::NULL, &:read)

        assert_equal '1 Field "at": the timeZone "America/New_York" needs the tzinfo gem, so add `gem "tzinfo"` to the ' \
                     'Gemfile, or use an offset, such as "-05:00": cannot load such file -- tzinfo', message
      end
    end

    describe "fields of the same name" do
      let(:schema) { {fields: [{name: "a", type: "integer"}, {name: "a"}, {name: "b"}]} }

      it "are accepted, as Frictionless requires, and read and write rows, matched to the columns in order" do
        path = IOStreams.path(dir, "same.csv").schema(schema)
        path.writer(:array) { |io| io << [1, "x", "y"] }

        assert_equal "a,a,b\n1,x,y\n", path.read
        rows = []
        path.each(:array) { |row| rows << row }

        assert_equal [%w[a a b], [1, "x", "y"]], rows
      end

      it "raise ArgumentError for records keyed by them, before the file is opened" do
        path = IOStreams.path(dir, "same.csv").schema(schema)

        assert_raises(ArgumentError) { path.each(:hash) { |record| record } }
        assert_raises(ArgumentError) { path.writer(:hash) { |io| io << {} } }
        refute_predicate path, :exist?
      end

      it "raise ArgumentError for a format whose rows are records, such as JSON, and for a contract" do
        assert_raises(ArgumentError) { IOStreams.path(dir, "same.json").schema(schema).writer(:array) { |io| io << [1, "x", "y"] } }
        refute_predicate IOStreams.path(dir, "same.json"), :exist?
        assert_raises(ArgumentError) { IOStreams::Contract.new(schema) }
      end

      it "raise ArgumentError for a key that names one of them" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(schema.merge(primaryKey: "a")) }
        assert_equal 'The schema primaryKey names "a", which is the name of 2 fields', error.message
      end

      it "check the unique values of each of them, also of two that are the same in every other way" do
        unique = {fields: [{name: "a", constraints: {unique: true}}, {name: "a", constraints: {unique: true}}]}
        File.write(File.join(dir, "u.csv"), "a,a\n1,1\n2,1\n")

        error = assert_raises(IOStreams::Errors::InvalidValue) { read_rows(IOStreams.path(dir, "u.csv").schema(unique)) }
        assert_equal 3, error.line_number
      end

      it "match the columns of the same name compared loosely in order, such as A and a" do
        File.write(File.join(dir, "l.csv"), "A,a,b\n1,x,y\n")

        assert_equal [%w[a a b], [1, "x", "y"]], read_rows(IOStreams.path(dir, "l.csv").schema(schema))
      end

      it "raise ArgumentError when one of them has aliases, since a column of an alias would not say which it is" do
        error = assert_raises(ArgumentError) { IOStreams::Schema.new(fields: [{name: "a", aliases: ["x"]}, {name: "a"}]) }
        assert_equal 'Field "a": a field whose name another field has too cannot have aliases, since a column of an alias ' \
                     "would not say which of them it is", error.message
      end

      it "name the number of columns and fields of the name when the file has more columns of it than the fields" do
        File.write(File.join(dir, "three.csv"), "a,a,a,b\n1,x,z,y\n")

        error = assert_raises(IOStreams::Errors::InvalidHeader) { read_rows(IOStreams.path(dir, "three.csv").schema(schema)) }
        assert_equal 'The columns have 3 columns named "a", while the schema has 2 fields of that name, each of which takes ' \
                     "one column, in order", error.message
      end

      it "raise ArgumentError for a contract read through the schema of the file, also in the :array mode" do
        contract = IOStreams::Contract.new(fieldsMatch: "subset", fields: [{name: "b"}])
        File.write(File.join(dir, "same.csv"), "a,a,b\n1,x,y\n")

        assert_raises(ArgumentError) { read_rows(IOStreams.path(dir, "same.csv").schema(schema).as(contract)) }
      end
    end

    it "keeps raising for geojson, which is not supported" do
      error = assert_raises(ArgumentError) { field(type: "geojson") }
      assert_equal 'Field "value": the type "geojson" is not supported', error.message
    end

    describe "in each format" do
      let(:schema) do
        {
          fields: [
            {name: "tags", type: "list"},
            {name: "scores", type: "list", itemType: "integer", delimiter: ";"},
            {name: "year", type: "year"},
            {name: "month", type: "yearmonth"},
            {name: "point", type: "geopoint"},
            {name: "place", type: "geopoint", format: "array"}
          ]
        }
      end

      let(:record) do
        {
          "tags" => %w[a b], "scores" => [1, 2], "year" => 2026, "month" => Date.new(2026, 10, 1),
          "point" => [BigDecimal("90.5"), BigDecimal("45.5")], "place" => [BigDecimal("1.5"), BigDecimal("-2")]
        }
      end

      it "writes CSV as the text of each, which reads back" do
        path = write("places.csv", schema, [record])

        assert_equal %(tags,scores,year,month,point,place\n"a,b",1;2,2026,2026-10,"90.5, 45.5","[1.5,-2]"\n), path.read
        assert_equal [record], read(path)
      end

      it "writes JSON with a list and a geopoint of the array format as arrays, which read back" do
        path = write("places.json", schema, [record])

        assert_equal %({"tags":["a","b"],"scores":[1,2],"year":2026,"month":"2026-10","point":"90.5, 45.5","place":[1.5,-2]}\n),
                     path.read
        assert_equal [record], read(path)
      end

      it "reads the numbers of a geopoint and of a list of numbers of JSON with every digit" do
        schema = {fields: [{name: "place", type: "geopoint", format: "array"}, {name: "rates", type: "list", itemType: "number"}]}
        File.write(File.join(dir, "rates.json"), %({"place":[90.12345678901234567,45.5],"rates":[0.1000000000000000055511151231257827]}\n))

        assert_equal [{"place" => [BigDecimal("90.12345678901234567"), BigDecimal("45.5")],
                       "rates" => [BigDecimal("0.1000000000000000055511151231257827")]}],
                     read(IOStreams.path(dir, "rates.json").schema(schema))
      end

      it "writes a fixed width file as the text of each, which reads back" do
        widths = [5, 5, 4, 7, 12, 10]
        fixed  = {fields: schema[:fields].zip(widths).map { |properties, width| properties.merge(width: width) }}
        path   = write("places.fixed", fixed, [record])

        assert_equal "a,b  1;2  20262026-1090.5, 45.5  [1.5,-2]  \n", path.read
        assert_equal [record], read(path)
      end

      it "writes a spreadsheet, whose cells hold the text of a list and a geopoint, as CSV does, which read back" do
        # creek on JRuby reads an inline string only up to a `]`, such as that of the JSON text of a geopoint array.
        path = IOStreams.path(dir, "places.xlsx").schema(schema)
        path = path.option(:xlsx, use_shared_strings: true) if defined?(JRuby)
        path.writer(:hash) { |io| io << record }

        assert_equal [record], read(path)
        lines = []
        IOStreams.path(dir, "places.xlsx").each(:line) { |line| lines << line }

        assert_equal %("a,b",1;2,2026,2026-10,"90.5, 45.5","[1.5,-2]"), lines.last
      end

      it "writes a list of numbers with decimals to a spreadsheet as its text, with its decimals, which reads back" do
        numbers = {fields: [{name: "rates", type: "list", itemType: "number", decimals: 2}]}
        path    = write("rates.xlsx", numbers, [{"rates" => [1.5, BigDecimal("2.255")]}])
        lines   = []
        IOStreams.path(dir, "rates.xlsx").each(:line) { |line| lines << line }

        assert_equal ["rates", %("1.50,2.26")], lines
        assert_equal [{"rates" => [BigDecimal("1.50"), BigDecimal("2.26")]}], read(path)
      end

      it "reads a number cell of a spreadsheet into a list as a list of that number, as the CSV text of the sheet reads" do
        IOStreams.path(dir, "cells.xlsx").writer(:array) do |io|
          io << %w[rates tags]
          io << [1.5, 42]
          io << ["1.5,2", "a,b"]
        end
        lists = {
          fields: [
            {name: "rates", type: "list", itemType: "number", decimals: 2},
            {name: "tags", type: "list"}
          ]
        }
        rows = [
          {"rates" => [BigDecimal("1.50")], "tags" => ["42"]},
          {"rates" => [BigDecimal("1.50"), BigDecimal("2.00")], "tags" => %w[a b]}
        ]

        assert_equal rows, read(IOStreams.path(dir, "cells.xlsx").schema(lists))
        lines = []
        IOStreams.path(dir, "cells.xlsx").each(:line) { |line| lines << line }
        IOStreams.path(dir, "cells.csv").writer(:line) { |io| lines.each { |line| io << line } }

        assert_equal rows, read(IOStreams.path(dir, "cells.csv").schema(lists))
      end

      it "reads a JSON number into a list as a list of that number, and an array as its items" do
        File.write(File.join(dir, "rates.json"), %({"rates":1.5}\n{"rates":[1.5,2]}\n{"rates":"1.5,2"}\n))
        records = read(IOStreams.path(dir, "rates.json").schema(fields: [{name: "rates", type: "list", itemType: "number"}]))
        rates   = records.map { |record| record["rates"] }

        assert_equal [[BigDecimal("1.5")], [BigDecimal("1.5"), BigDecimal("2")], [BigDecimal("1.5"), BigDecimal("2")]], rates
      end

      it "reads a Parquet column of numbers into a list as a list of that number, also through a contract" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        write("rates.parquet", {fields: [{name: "rates", type: "number", decimals: 2}]}, [{"rates" => BigDecimal("1.5")}])
        lists = {fields: [{name: "rates", type: "list", itemType: "number"}]}

        assert_equal [{"rates" => [BigDecimal("1.5")]}], read(IOStreams.path(dir, "rates.parquet").schema(lists))
        assert_equal [{"rates" => [BigDecimal("1.5")]}], read(IOStreams.path(dir, "rates.parquet").as(lists))
        error = assert_raises(IOStreams::Errors::IncompatibleType) do
          read(IOStreams.path(dir, "rates.parquet").as(fields: [{name: "rates", type: "list", itemType: "date"}]))
        end
        assert_includes error.message, "which the list field \"rates\" never accepts"
      end

      it "writes Parquet, a list as a Parquet list, the text of a yearmonth and a geopoint, and an int64 of a year" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        path = write("places.parquet", schema, [record])

        assert_equal [record], read(path)
        types = IOStreams.path(dir, "places.parquet").infer_schema.fields.to_h { |field| [field.name, field.type] }

        assert_equal({"tags" => "array", "scores" => "array", "year" => "integer", "month" => "string",
                      "point" => "string", "place" => "string"}, types)
        lists = read(IOStreams.path(dir, "places.parquet")).map { |row| row.slice("tags", "scores") }

        assert_equal [{"tags" => %w[a b], "scores" => [1, 2]}], lists
      end

      it "writes a list of each itemType as a Parquet list, which reads back" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        lists = {
          fields: %w[string integer boolean number datetime date time].map do |type|
            {name: type, type: "list", itemType: type, **(type == "number" ? {decimals: 3} : {})}
          end
        }
        record = {
          "string"   => ["a", nil, "b,c"],
          "integer"  => [1, 2**62],
          "boolean"  => [true, false],
          "number"   => [BigDecimal("1.25"), BigDecimal("12345678901234567890.123")],
          "datetime" => [Time.utc(2026, 1, 2, 3, 4, 5)],
          "date"     => [Date.new(2024, 2, 29)],
          "time"     => [Time.utc(2000, 1, 1, 9, 30)]
        }
        empty  = {"string" => [], "integer" => nil, "boolean" => nil, "number" => nil, "datetime" => nil, "date" => nil, "time" => nil}
        path   = write("lists.parquet", lists, [record, {"string" => [], "integer" => nil}])

        assert_equal [record, empty], read(path)
      end

      it "writes a list of numbers to Parquet as a list of decimals of its decimals, or of doubles with floatNumber" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        lists = {
          fields: [
            {name: "rates", type: "list", itemType: "number", decimals: 2},
            {name: "ratios", type: "list", itemType: "number", floatNumber: true}
          ]
        }
        path = write("numbers.parquet", lists, [{"rates" => [BigDecimal("1.5"), BigDecimal("2.255"), nil], "ratios" => [0.5, nil]}])

        assert_equal [{"rates" => [BigDecimal("1.50"), BigDecimal("2.26"), nil], "ratios" => [0.5, nil]}], read(path)
        rows = read(IOStreams.path(dir, "numbers.parquet"))

        assert_equal [[BigDecimal, NilClass], [Float, NilClass]], [rows.first["rates"].map(&:class).uniq, rows.first["ratios"].map(&:class).uniq]
        assert_equal [BigDecimal("1.50"), BigDecimal("2.26"), nil], rows.first["rates"]
      end

      it "writes the decimals of a list of numbers as the scale of its Parquet decimals" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        # The parquet gem reports the type of the items of a list only in the Arrow schema that it stores in the file,
        # whose Decimal holds its scale and precision as two little-endian Int32s.
        [2, 3].each do |decimals|
          path   = write("rates#{decimals}.parquet", {fields: [{name: "rates", type: "list", itemType: "number", decimals: decimals}]},
                         [{"rates" => [BigDecimal("1.5")]}])
          stored = ::Parquet.metadata(path.to_s)["key_value_metadata"].find { |pair| pair["key"] == "ARROW:schema" }
          arrow  = stored["value"].unpack1("m")

          assert_includes arrow, [decimals, 38].pack("l<l<")
          refute_includes arrow, [5 - decimals, 38].pack("l<l<")
        end
      end

      it "raises for a list of numbers written to Parquet without decimals or floatNumber, as for a number" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        error = assert_raises(ArgumentError) do
          write("numbers.parquet", {fields: [{name: "rates", type: "list", itemType: "number"}]}, [{"rates" => [1]}])
        end
        assert_equal 'Field "rates": a number written to Parquet needs `decimals`, the digits after its decimal point, ' \
                     "for a decimal, or `floatNumber: true` for a double", error.message
      end

      it "keeps them in a slice of typed values stored as JSON" do
        slice  = IOStreams::Slice.new([record], format: :hash, schema: IOStreams::Schema.new(schema))
        stored = IOStreams.slice(JSON.parse(JSON.generate(slice.to_h)))
        rows   = []
        IOStreams.stream(stored).schema(schema).each(:hash) { |row| rows << row }

        assert_equal [record], rows
      end

      it "keeps them in a slice of a Parquet file stored as JSON" do
        skip "The parquet gem is a Rust extension, which JRuby cannot load" if defined?(JRuby)

        slices = []
        IOStreams.path(write("places.parquet", schema, [record]).to_s).each(:slice, size: 10) { |slice| slices << slice }
        stored = IOStreams.slice(JSON.parse(JSON.generate(slices.first.to_h)))
        rows   = []
        IOStreams.stream(stored).schema(schema).each(:hash) { |row| rows << row }

        assert_equal [record], rows
      end
    end
  end
end
