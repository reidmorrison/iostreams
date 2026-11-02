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
        assert_raises(IOStreams::Errors::InvalidValue) { list.cast(5) }
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
        ["2026-13", "2026-1", "2026-10-01", "10/2026"].each do |text|
          assert_raises(IOStreams::Errors::InvalidValue, text) { month.cast(text) }
        end
        assert_raises(IOStreams::Errors::InvalidValue) { month.cast(Date.new(2026, 10, 2)) }
        assert_raises(IOStreams::Errors::InvalidValue) { month.cast(Date.new(10_000, 1, 1)) }
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
